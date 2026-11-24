import SwiftUI
import UIKit

// MARK: - Typography settings

enum BookFont: String, CaseIterable, Identifiable, Sendable {
    case newYork, georgia, palatino, iowan, charter, baskerville, sans, avenir
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newYork: "New York"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .iowan: "Iowan Old Style"
        case .charter: "Charter"
        case .baskerville: "Baskerville"
        case .sans: "San Francisco"
        case .avenir: "Avenir Next"
        }
    }
    private var family: String? {
        switch self {
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .iowan: "Iowan Old Style"
        case .charter: "Charter"
        case .baskerville: "Baskerville"
        case .avenir: "Avenir Next"
        case .newYork, .sans: nil
        }
    }
    func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        var descriptor: UIFontDescriptor
        if let family {
            descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        } else {
            let base = UIFont.systemFont(ofSize: size).fontDescriptor
            descriptor = self == .newYork ? (base.withDesign(.serif) ?? base) : base
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) { descriptor = styled }
        return UIFont(descriptor: descriptor, size: size)
    }
}

enum BookTheme: String, CaseIterable, Identifiable, Sendable {
    case night, dusk, sepia, paper
    var id: String { rawValue }
    var title: String { ["night": "Night", "dusk": "Dusk", "sepia": "Sepia", "paper": "Paper"][rawValue] ?? "" }
    var background: UIColor {
        switch self {
        case .night: UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        case .dusk: UIColor(red: 0.12, green: 0.105, blue: 0.09, alpha: 1)
        case .sepia: UIColor(red: 0.957, green: 0.925, blue: 0.847, alpha: 1)
        case .paper: UIColor(red: 0.985, green: 0.98, blue: 0.965, alpha: 1)
        }
    }
    var text: UIColor {
        switch self {
        case .night: UIColor(red: 0.89, green: 0.87, blue: 0.83, alpha: 1)
        case .dusk: UIColor(red: 0.9, green: 0.83, blue: 0.71, alpha: 1)
        case .sepia: UIColor(red: 0.23, green: 0.18, blue: 0.13, alpha: 1)
        case .paper: UIColor(red: 0.1, green: 0.1, blue: 0.11, alpha: 1)
        }
    }
    var secondary: UIColor { text.withAlphaComponent(0.5) }
    var dark: Bool { self == .night || self == .dusk }
}

struct BookStyle: Equatable, Sendable {
    var font: BookFont
    var size: Double
    var spacing: Double
    /// 0 narrow, 1 normal, 2 wide.
    var margin: Int
    var justify: Bool
    var theme: BookTheme
    var key: String { "\(font.rawValue)|\(size)|\(spacing)|\(margin)|\(justify)|\(theme.rawValue)" }
}

// MARK: - Typesetting and pagination (off the main thread)

struct BookPageRef: Sendable, Equatable {
    let section: Int
    let range: NSRange
}

/// The set book: one attributed string per section and every page's place in them. Immutable once built.
final class TypesetBook: @unchecked Sendable {
    private(set) var sections: [NSAttributedString]
    @MainActor func applyHighlight(section: Int, offset: Int, quote: String) {
        guard sections.indices.contains(section), offset >= 0 else { return }
        let text = NSMutableAttributedString(attributedString: sections[section])
        let length = (quote as NSString).length
        guard offset <= text.length, length <= text.length - offset else { return }
        let range = NSRange(location: offset, length: length)
        guard (text.string as NSString).substring(with: range) == quote else { return }
        text.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.36), range: range)
        sections[section] = text
    }
    let pages: [BookPageRef]
    let sectionStarts: [Int]
    let pageSize: CGSize
    init(sections: [NSAttributedString], pages: [BookPageRef], sectionStarts: [Int], pageSize: CGSize) {
        self.sections = sections; self.pages = pages; self.sectionStarts = sectionStarts; self.pageSize = pageSize
    }
    /// The text of one page, ready to draw. A page that starts mid-paragraph doesn't indent its first line.
    func text(of index: Int) -> NSAttributedString {
        guard pages.indices.contains(index) else { return NSAttributedString() }
        let ref = pages[index]
        let source = sections[ref.section]
        guard NSMaxRange(ref.range) <= source.length else { return NSAttributedString() }
        let slice = NSMutableAttributedString(attributedString: source.attributedSubstring(from: ref.range))
        let full = source.string as NSString
        if ref.range.location > 0, full.character(at: ref.range.location - 1) != 10, slice.length > 0 {
            let firstParagraph = (slice.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            if let style = slice.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
               let copy = style.mutableCopy() as? NSMutableParagraphStyle {
                copy.firstLineHeadIndent = copy.headIndent
                copy.paragraphSpacingBefore = 0
                slice.addAttribute(.paragraphStyle, value: copy, range: firstParagraph)
            }
        }
        return slice
    }
    func page(for section: Int, offset: Int) -> Int {
        guard sectionStarts.indices.contains(section) else { return 0 }
        let start = sectionStarts[section]
        let end = section + 1 < sectionStarts.count ? sectionStarts[section + 1] : pages.count
        for i in start..<max(start, end) where NSMaxRange(pages[i].range) > offset { return i }
        return start
    }
    func pagesIn(section: Int) -> Int {
        guard sectionStarts.indices.contains(section) else { return 0 }
        let end = section + 1 < sectionStarts.count ? sectionStarts[section + 1] : pages.count
        return max(0, end - sectionStarts[section])
    }
}

enum BookTypesetter {
    static func typeset(_ document: BookDocument, images: [String: Data], style: BookStyle, pageSize: CGSize) -> TypesetBook {
        var sections: [NSAttributedString] = []
        var pages: [BookPageRef] = []
        var starts: [Int] = []
        for (index, section) in document.sections.enumerated() {
            var text = attributed(section, images: images, style: style, pageSize: pageSize)
            if text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A title page drawn as a picture iOS can't show (SVG): set the title as type instead.
                text = titlePage(document: document, section: section, index: index, style: style, pageSize: pageSize)
            }
            sections.append(text)
            starts.append(pages.count)
            let ranges = paginate(text, size: pageSize)
            pages += ranges.map { BookPageRef(section: index, range: $0) }
            if ranges.isEmpty { pages.append(BookPageRef(section: index, range: NSRange(location: 0, length: 0))) }
        }
        return TypesetBook(sections: sections, pages: pages, sectionStarts: starts, pageSize: pageSize)
    }

    /// One section in book typography: justified and hyphenated, indented paragraphs, a chapter
    /// opener with space above, a raised initial, and pictures fitted to the page.
    static func attributed(_ section: BookSection, images: [String: Data], style: BookStyle, pageSize: CGSize) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let size = CGFloat(style.size)
        let color = style.theme.text
        let indent = size * 1.4
        var afterBreak = true      // first paragraph after a heading, rule or picture: no indent
        var firstParagraph = true  // raised initial on the section's first paragraph
        var leadingHeading = true  // headings before any text open the chapter
        func paragraph(_ alignment: NSTextAlignment, indent first: CGFloat = 0, head: CGFloat = 0, tail: CGFloat = 0,
                       before: CGFloat = 0, after: CGFloat = 0, hyphenate: Bool = true) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.alignment = alignment
            p.firstLineHeadIndent = first + head
            p.headIndent = head
            p.tailIndent = -tail
            p.lineHeightMultiple = CGFloat(style.spacing)
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.hyphenationFactor = hyphenate && style.justify ? 0.9 : 0
            p.lineBreakStrategy = .standard
            return p
        }
        func runs(_ list: [BookRun], size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSMutableAttributedString {
            let text = NSMutableAttributedString()
            for run in list {
                let font: UIFont
                if run.mono {
                    font = UIFont.monospacedSystemFont(ofSize: size * 0.88, weight: run.bold ? .semibold : .regular)
                } else {
                    font = style.font.font(run.small ? size * 0.85 : size, bold: run.bold || bold, italic: run.italic != italic)
                }
                text.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: color]))
            }
            return text
        }
        for block in section.blocks {
            switch block {
            case .heading(let level, let list):
                let scale: CGFloat = [1: 1.6, 2: 1.4, 3: 1.2][level] ?? 1.1
                let opener = leadingHeading && level <= 3
                let p = paragraph(.center, before: opener ? pageSize.height * (out.length == 0 ? 0.16 : 0.02) : size * 1.2,
                                  after: size * (opener ? 1.6 : 0.8), hyphenate: false)
                let text = runs(list, size: size * scale, bold: level >= 3)
                if level <= 2 { text.addAttribute(.kern, value: size * 0.04, range: NSRange(location: 0, length: text.length)) }
                text.append(NSAttributedString(string: "\n"))
                text.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: text.length))
                out.append(text)
                afterBreak = true
            case .paragraph(let list), .quote(let list), .centered(let list), .listItem(let list, _):
                leadingHeading = false
                var p: NSMutableParagraphStyle
                var text: NSMutableAttributedString
                switch block {
                case .quote:
                    p = paragraph(style.justify ? .justified : .natural, head: indent, tail: indent, before: size * 0.4, after: size * 0.4)
                    text = runs(list, size: size * 0.95)
                case .centered:
                    p = paragraph(.center, before: size * 0.5, after: size * 0.5, hyphenate: false)
                    text = runs(list, size: size)
                case .listItem(_, let marker):
                    p = paragraph(.natural, head: indent, before: size * 0.15)
                    p.firstLineHeadIndent = indent * 0.35
                    text = NSMutableAttributedString(string: marker + "\u{2002}", attributes: [.font: style.font.font(size), .foregroundColor: color])
                    text.append(runs(list, size: size))
                default:
                    p = paragraph(style.justify ? .justified : .natural, indent: afterBreak ? 0 : indent)
                    text = runs(list, size: size)
                    // Raised initial: the chapter's first letter set large, like a printed book.
                    if firstParagraph, text.length > 1, let first = text.string.first, first.isLetter {
                        let length = (String(first) as NSString).length
                        text.addAttribute(.font, value: style.font.font(size * 2.1, bold: false), range: NSRange(location: 0, length: length))
                    }
                    firstParagraph = false
                }
                text.append(NSAttributedString(string: "\n"))
                text.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: text.length))
                out.append(text)
                afterBreak = false
            case .preformatted(let raw):
                leadingHeading = false
                let p = paragraph(.natural, head: indent * 0.5, before: size * 0.4, after: size * 0.4, hyphenate: false)
                out.append(NSAttributedString(string: raw + "\n", attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: size * 0.8, weight: .regular), .foregroundColor: color, .paragraphStyle: p]))
                afterBreak = true
            case .image(let path):
                guard let data = images[path], let image = UIImage(data: data), image.size.width > 0 else { continue }
                leadingHeading = false
                let maxW = pageSize.width, maxH = pageSize.height * 0.82
                let scale = min(1, min(maxW / image.size.width, maxH / image.size.height), max(1, maxW * 0.6 / image.size.width))
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: 0, width: floor(image.size.width * scale), height: floor(image.size.height * scale))
                let text = NSMutableAttributedString(attachment: attachment)
                text.append(NSAttributedString(string: "\n"))
                text.addAttribute(.paragraphStyle, value: paragraph(.center, before: size * 0.6, after: size * 0.6, hyphenate: false),
                                  range: NSRange(location: 0, length: text.length))
                out.append(text)
                afterBreak = true
            case .rule:
                let p = paragraph(.center, before: size * 0.8, after: size * 0.8, hyphenate: false)
                out.append(NSAttributedString(string: "⁂\n", attributes: [.font: style.font.font(size), .foregroundColor: style.theme.secondary, .paragraphStyle: p]))
                afterBreak = true
            }
        }
        return out
    }

    static func titlePage(document: BookDocument, section: BookSection, index: Int, style: BookStyle, pageSize: CGSize) -> NSAttributedString {
        let name = (section.title ?? "").trimmingCharacters(in: .whitespaces)
        let generic = ["", "titlepage", "title page", "title", "cover", "half title", "halftitle"].contains(name.lowercased())
        let size = CGFloat(style.size)
        let out = NSMutableAttributedString()
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacingBefore = pageSize.height * 0.24
        p.paragraphSpacing = size * 1.2
        out.append(NSAttributedString(string: (generic ? document.title : name) + "\n", attributes: [
            .font: style.font.font(size * (generic ? 1.9 : 1.5), bold: false), .foregroundColor: style.theme.text, .paragraphStyle: p]))
        if generic, let author = document.author, !author.isEmpty {
            let a = NSMutableParagraphStyle()
            a.alignment = .center
            out.append(NSAttributedString(string: author + "\n", attributes: [
                .font: style.font.font(size * 1.05, bold: false, italic: true), .foregroundColor: style.theme.secondary, .paragraphStyle: a]))
        }
        return out
    }

    /// Splits text into page-sized ranges with TextKit (each page is a text container of the page's size).
    static func paginate(_ text: NSAttributedString, size: CGSize) -> [NSRange] {
        guard text.length > 0, size.width > 40, size.height > 60 else { return [] }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        storage.addLayoutManager(manager)
        var ranges: [NSRange] = []
        var guardCount = 0
        while guardCount < 20_000 {
            guardCount += 1
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let glyphs = manager.glyphRange(for: container)
            if glyphs.length == 0 { break }
            ranges.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            if NSMaxRange(glyphs) >= manager.numberOfGlyphs { break }
        }
        return ranges
    }
}

// MARK: - Pages on screen

/// One printed page: running head, the text drawn as real type (sharp at any zoom), folio.
final class BookPageView: UIView {
    var text = NSAttributedString() { didSet { setNeedsDisplay() } }
    var head = "" { didSet { setNeedsDisplay() } }
    var folio = "" { didSet { setNeedsDisplay() } }
    var theme: BookTheme = .night { didSet { backgroundColor = theme.background; setNeedsDisplay() } }
    var textInsets = UIEdgeInsets(top: 48, left: 28, bottom: 44, right: 28) { didSet { setNeedsDisplay() } }
    /// Spine side gets a soft shadow in two-page spreads (−1 left page, 1 right page, 0 single).
    var spine: Int = 0 { didSet { setNeedsDisplay() } }
    var tapped: ((CGFloat) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isOpaque = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        let width = window?.bounds.width ?? bounds.width
        tapped?(width > 0 ? min(1, max(0, recognizer.location(in: window ?? self).x / width)) : 0.5)
    }
    override func draw(_ rect: CGRect) {
        theme.background.setFill()
        UIRectFill(bounds)
        if spine != 0, let context = UIGraphicsGetCurrentContext() {
            let edge = spine < 0 ? bounds.maxX : bounds.minX
            let colors = [UIColor.black.withAlphaComponent(theme.dark ? 0.35 : 0.12).cgColor, UIColor.clear.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: edge, y: 0), end: CGPoint(x: edge + CGFloat(-spine) * 26, y: 0), options: [])
            }
        }
        let small = UIFont.systemFont(ofSize: 11, weight: .medium)
        let center = NSMutableParagraphStyle(); center.alignment = .center; center.lineBreakMode = .byTruncatingTail
        let headRect = CGRect(x: textInsets.left, y: max(14, textInsets.top - 30), width: bounds.width - textInsets.left - textInsets.right, height: 16)
        (head.uppercased() as NSString).draw(in: headRect, withAttributes: [.font: small, .kern: 1.4, .foregroundColor: theme.secondary, .paragraphStyle: center])
        let textRect = bounds.inset(by: textInsets)
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let folioRect = CGRect(x: textInsets.left, y: bounds.height - textInsets.bottom + 14, width: textRect.width, height: 16)
        (folio as NSString).draw(in: folioRect, withAttributes: [.font: small.withSize(12), .foregroundColor: theme.secondary, .paragraphStyle: center])
    }
}

final class BookPageController: UIViewController {
    let index: Int
    let pageView = BookPageView()
    init(index: Int) { self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func loadView() { view = pageView }
}

/// Page curl (or slide), left to right like a printed book; two pages side by side in wide landscape.
final class BookPagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private var pager: UIPageViewController?
    private var book: TypesetBook?
    private var style: BookStyle?
    private var insets = UIEdgeInsets.zero
    private var twoUp = false
    private var curl = true
    private var title_ = ""
    private(set) var current = 0
    var changed: ((Int) -> Void)?
    var tapped: ((CGFloat) -> Void)?
    /// A turn past the last page (true) or before the first (false): the novel reader opens the next or previous chapter.
    var beyondEnd: ((Bool) -> Void)?
    var sectionTitle: ((Int) -> String)?
    private var layoutKey = ""
    /// A page turn is animating (a tap, a key, or a finger mid-curl). UIPageViewController crashes if its
    /// pages are replaced during one, so changes wait until it ends.
    private var animating = false
    private var pending: (() -> Void)?

    func configure(book: TypesetBook, style: BookStyle, insets: UIEdgeInsets, twoUp: Bool, curl: Bool, title: String, page: Int) {
        guard !animating else {
            pending = { [weak self] in self?.configure(book: book, style: style, insets: insets, twoUp: twoUp, curl: curl, title: title, page: page) }
            return
        }
        loadViewIfNeeded()
        let key = "\(ObjectIdentifier(book))|\(style.key)|\(insets)|\(twoUp)|\(curl)"
        self.book = book; self.style = style; self.insets = insets; self.title_ = title
        let target = min(max(0, page), max(0, book.pages.count - 1))
        if key != layoutKey {
            layoutKey = key
            self.twoUp = twoUp; self.curl = curl
            current = target
            rebuild()
        } else if target != current {
            jump(to: target)
        }
    }
    private func settled() {
        animating = false
        if let next = pending { pending = nil; next() }
    }
    private func rebuild() {
        animating = false
        if let pager { pager.willMove(toParent: nil); pager.view.removeFromSuperview(); pager.removeFromParent() }
        let options: [UIPageViewController.OptionsKey: Any]? = curl
            ? [.spineLocation: NSNumber(value: (twoUp ? UIPageViewController.SpineLocation.mid : .min).rawValue)] : [.interPageSpacing: 0]
        let controller = UIPageViewController(transitionStyle: curl && !UIAccessibility.isReduceMotionEnabled ? .pageCurl : .scroll,
                                              navigationOrientation: .horizontal, options: options)
        controller.view.semanticContentAttribute = .forceLeftToRight
        controller.isDoubleSided = curl && twoUp
        controller.dataSource = self; controller.delegate = self
        // Taps are ours (edges turn, middle shows controls); the curl's own tap-to-turn would double up.
        for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer { recognizer.isEnabled = false }
        // Pages go in before the pager is on screen: UIKit can ask for the spine location as soon as it's added,
        // and a page curl with no pages at that moment throws.
        controller.setViewControllers(visible(for: current), direction: .forward, animated: false)
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        pager = controller
    }
    /// The page (or the left/right pair) that shows `index`.
    private func visible(for index: Int) -> [UIViewController] {
        guard twoUp && curl else { return [page(index)] }
        let left = index - index % 2
        return [page(left), page(left + 1)]
    }
    private func page(_ index: Int) -> BookPageController {
        let controller = BookPageController(index: index)
        controller.loadViewIfNeeded()
        let view = controller.pageView
        view.theme = style?.theme ?? .night
        view.textInsets = insets
        view.spine = twoUp && curl ? (index % 2 == 0 ? -1 : 1) : 0
        view.tapped = { [weak self] x in self?.tapped?(x) }
        if let book, book.pages.indices.contains(index) {
            let text = book.text(of: index)
            view.text = text
            let section = book.pages[index].section
            let chapterTitle = sectionTitle?(section) ?? ""
            view.head = index % 2 == 0 && twoUp ? title_ : chapterTitle
            view.folio = "\(index + 1)"
            view.accessibilityLabel = text.string
        }
        return controller
    }
    func refreshHighlights() {
        guard let book else { return }
        for case let shown as BookPageController in pager?.viewControllers ?? [] {
            shown.pageView.text = book.text(of: shown.index)
        }
    }
    func jump(to index: Int, animated: Bool = false) {
        guard let pager, let book, book.pages.indices.contains(index) else { return }
        guard !animating else { pending = { [weak self] in self?.jump(to: index) }; return }
        let forward = index > current
        current = index
        let animate = animated && !UIAccessibility.isReduceMotionEnabled
        if animate { animating = true }
        pager.setViewControllers(visible(for: index), direction: forward ? .forward : .reverse, animated: animate) { [weak self] _ in
            if animate { self?.settled() }
        }
    }
    /// Turn one page (or one spread) with the usual animation. Taps during a turn are ignored.
    func turn(forward: Bool) {
        guard let book, !animating else { return }
        let step = twoUp && curl ? 2 : 1
        let target = forward ? current - current % step + step : current - current % step - step
        guard target >= 0, target < book.pages.count else { beyondEnd?(forward); return }
        jump(to: target, animated: true)
        changed?(current)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? BookPageController)?.index, index > 0 else { return nil }
        return page(index - 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? BookPageController)?.index, let book else { return nil }
        // In spreads the last right-hand page may be blank.
        let limit = twoUp && curl ? book.pages.count + book.pages.count % 2 : book.pages.count
        guard index + 1 < limit else { return nil }
        return page(index + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        animating = true
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        defer { settled() }
        guard completed, let index = (pageViewController.viewControllers?.first as? BookPageController)?.index else { return }
        current = min(index, max(0, (book?.pages.count ?? 1) - 1))
        changed?(current)
    }
    func pageViewController(_ pageViewController: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
        guard curl else { return .none }
        pageViewController.isDoubleSided = twoUp
        // The spine returned here needs exactly one page (or two for a spread) already set, or UIKit throws.
        let have = pageViewController.viewControllers?.count ?? 0
        if !animating && (twoUp || have != 1) {
            pageViewController.setViewControllers(visible(for: current), direction: .forward, animated: false)
        }
        return twoUp ? .mid : .min
    }
}

struct BookPagerView: UIViewControllerRepresentable {
    let book: TypesetBook
    let style: BookStyle
    let insets: UIEdgeInsets
    let twoUp: Bool
    let curl: Bool
    let title: String
    let sectionTitle: (Int) -> String
    @Binding var page: Int
    let controller: BookPagerController
    let tapped: (CGFloat) -> Void
    func makeUIViewController(context: Context) -> BookPagerController { controller }
    func updateUIViewController(_ vc: BookPagerController, context: Context) {
        vc.changed = { page = $0 }
        vc.tapped = tapped
        vc.sectionTitle = sectionTitle
        vc.configure(book: book, style: style, insets: insets, twoUp: twoUp, curl: curl, title: title, page: page)
    }
}

// MARK: - The reader

/// Reads a book like a book: left to right, page curl, running heads and page numbers,
/// your font, size, spacing, margins and paper colour.
struct BookReaderView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let chapter: Chapter
    @AppStorage("bookFont") private var fontRaw = BookFont.newYork.rawValue
    @AppStorage("bookSize") private var size = 19.0
    @AppStorage("bookSpacing") private var spacing = 1.4
    @AppStorage("bookMargin") private var margin = 1
    @AppStorage("bookJustify") private var justify = true
    @AppStorage("bookTheme") private var themeRaw = BookTheme.night.rawValue
    @AppStorage("bookCurl") private var curl = true
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    @AppStorage("pageHaptics") private var haptics = true
    @State private var document: BookDocument?
    @State private var images: [String: Data] = [:]
    @StateObject private var speaker = PassageSpeaker()
    @State private var passageTools = false
    @State private var beforeSearch: BookPageRef?
    @State private var typeset: TypesetBook?
    @State private var page = 0
    @State private var chrome = true
    @State private var failure: String?
    @State private var settings = false
    @State private var contents = false
    @State private var pager = BookPagerController()
    @State private var lastActivity = Date()
    /// Where to land once the book is set: from the library, or the current spot after a re-layout.
    @State private var anchor: BookPosition?
    /// The largest safe area seen for each screen shape. Hiding the controls hides the status bar, which
    /// shrinks the safe area; laying the book out again then (and swapping pages mid-turn) crashed the reader.
    @State private var steadySafe: [String: EdgeInsets] = [:]

    private var style: BookStyle {
        BookStyle(font: BookFont(rawValue: fontRaw) ?? .newYork, size: size, spacing: spacing, margin: margin,
                  justify: justify, theme: BookTheme(rawValue: themeRaw) ?? .night)
    }
    private var series: MangaSeries? { library.series(containing: chapter) }
    private var theme: BookTheme { style.theme }

    var body: some View {
        GeometryReader { geometry in
            let full = CGSize(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                              height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            let shape = "\(Int(full.width))x\(Int(full.height))"
            let safe = Self.merge(steadySafe[shape], geometry.safeAreaInsets)
            let twoUp = curl && full.width > full.height * 1.2 && full.width > 700
            let insets = Self.insets(for: full, twoUp: twoUp, margin: margin, safe: safe)
            let pageSize = CGSize(width: (twoUp ? full.width / 2 : full.width) - insets.left - insets.right,
                                  height: full.height - insets.top - insets.bottom)
            ZStack {
                Color(theme.background).ignoresSafeArea()
                if let typeset {
                    BookPagerView(book: typeset, style: style, insets: insets, twoUp: twoUp, curl: curl,
                                  title: series?.title ?? document?.title ?? "", sectionTitle: { sectionTitle($0) },
                                  page: $page, controller: pager, tapped: { tapped(at: $0) })
                        .ignoresSafeArea()
                } else if let failure {
                    VStack(spacing: 14) {
                        Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(Color(theme.secondary))
                        Text(failure).multilineTextAlignment(.center).foregroundStyle(Color(theme.text))
                        Button("Close") { dismiss() }.buttonStyle(.borderedProminent).tint(Eclipse.accent)
                    }.padding(32).frame(maxWidth: 460)
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(Color(theme.text))
                        Text("Setting type…").font(.footnote).foregroundStyle(Color(theme.secondary))
                    }
                }
                if chrome || typeset == nil { controls(pages: typeset?.pages.count ?? 0) }
            }
            // Runs again when the book finishes loading (it usually isn't loaded yet when the page first appears),
            // and whenever the page size or type settings change.
            .task(id: "\(document == nil ? "loading" : "ready")|\(Int(pageSize.width))x\(Int(pageSize.height))|\(style.key)|\(twoUp)") {
                await layout(pageSize: pageSize)
            }
            .onChange(of: geometry.safeAreaInsets, initial: true) { _, now in
                let merged = Self.merge(steadySafe[shape], now)
                if steadySafe[shape] != merged { steadySafe[shape] = merged }
            }
        }
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .preferredColorScheme(theme.dark ? .dark : .light)
        .animation(.snappy(duration: 0.2), value: chrome)
        .task { await load() }
        .background(KeyTurnCatcher().frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: PageTurnInput.notification)) { note in
            if let forward = note.userInfo?["forward"] as? Bool { pager.turn(forward: forward) }
            else if let edge = note.userInfo?["edge"] as? Double {
                if edge == 0.5 { chrome.toggle() } else { pager.turn(forward: edge > 0.5) }
            }
        }
        .userActivity(Handoff.readingType, isActive: typeset != nil) { activity in
            guard let typeset, typeset.pages.indices.contains(page), let part = series?.chapters[safe: typeset.pages[page].section] else { return }
            activity.title = series?.title
            activity.userInfo = ["chapter": part.id, "section": typeset.pages[page].section, "offset": typeset.pages[page].range.location]
            activity.isEligibleForHandoff = true
        }
        .onChange(of: page) { old, new in pageChanged(from: old, to: new) }
        .onChange(of: phase) { _, now in if now != .active { logTime() } else { lastActivity = Date() } }
        .onAppear { lastActivity = Date(); UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
        .onDisappear { speaker.stop(); logTime(); UIApplication.shared.isIdleTimerDisabled = false }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: page) { _, _ in haptics }
        .sheet(isPresented: $passageTools) {
            if let typeset {
                PassageTools(book: typeset, page: page, sections: typeset.sections.count, title: sectionTitle, jump: { section, offset in
                    beforeSearch = typeset.pages[safe: page]
                    page = typeset.page(for: section, offset: offset)
                }, annotate: { section, offset, quote, note in
                    guard let series, let part = series.chapters[safe: section] else { return }
                    var mark = Bookmark(seriesID: series.id, chapterID: part.id, chapterTitle: sectionTitle(section),
                                        page: typeset.page(for: section, offset: offset), pageCount: typeset.pages.count,
                                        offset: offset, section: section, note: note.isEmpty ? quote : quote + "\n" + note)
                    mark.highlightText = quote
                    library.addBookmark(mark)
                    typeset.applyHighlight(section: section, offset: offset, quote: quote)
                    pager.refreshHighlights()
                }, speaker: speaker)
            }
        }
        .sheet(isPresented: $settings) {
            BookSettingsSheet(fontRaw: $fontRaw, size: $size, spacing: $spacing, margin: $margin, justify: $justify,
                              themeRaw: $themeRaw, curl: $curl)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $contents) {
            if let typeset {
                BookContentsSheet(titles: (0..<typeset.sectionStarts.count).map { sectionTitle($0) },
                                  starts: typeset.sectionStarts, current: typeset.pages.indices.contains(page) ? typeset.pages[page].section : 0) { section in
                    contents = false
                    page = typeset.sectionStarts[section]
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Layout

    static func merge(_ a: EdgeInsets?, _ b: EdgeInsets) -> EdgeInsets {
        guard let a else { return b }
        return EdgeInsets(top: max(a.top, b.top), leading: max(a.leading, b.leading),
                          bottom: max(a.bottom, b.bottom), trailing: max(a.trailing, b.trailing))
    }

    /// Generous margins that keep lines to a comfortable measure, plus room for the running head and folio.
    static func insets(for size: CGSize, twoUp: Bool, margin: Int, safe: EdgeInsets) -> UIEdgeInsets {
        let pageWidth = twoUp ? size.width / 2 : size.width
        let base: CGFloat = [16, 26, 40][min(2, max(0, margin))]
        // ~70 characters a line at most, however wide the screen.
        let measure: CGFloat = 620
        let side = max(base, (pageWidth - measure) / 2)
        return UIEdgeInsets(top: max(54, safe.top + 34), left: max(side, twoUp ? base : safe.leading + base),
                            bottom: max(48, safe.bottom + 34), right: max(side, twoUp ? base : safe.trailing + base))
    }

    private func load() async {
        guard let file = BookLink.file(of: chapter.url) else { failure = "This book's file is missing."; return }
        do {
            let book = try await BookStore.shared.document(file)
            var found: [String: Data] = [:]
            for section in book.sections {
                for block in section.blocks {
                    if case .image(let path) = block, found[path] == nil, let data = await BookStore.shared.image(file, path: path) { found[path] = data }
                }
            }
            images = found
            // Open where you left off when continuing this part, else at the start of the chosen part.
            let section = BookLink.section(of: chapter)
            if let saved = series.flatMap({ library.bookPosition($0.id) }), saved.section == section {
                anchor = saved
            } else {
                anchor = BookPosition(section: section, offset: 0)
            }
            document = book
        } catch {
            failure = error.localizedDescription
        }
    }
    private func layout(pageSize: CGSize) async {
        guard let document, pageSize.width > 60, pageSize.height > 80 else { return }
        // Keep your place across font changes and rotation.
        if let typeset, typeset.pages.indices.contains(page) {
            let ref = typeset.pages[page]
            anchor = BookPosition(section: ref.section, offset: ref.range.location)
        }
        let style = self.style, images = self.images
        let result = await Task.detached(priority: .userInitiated) {
            BookTypesetter.typeset(document, images: images, style: style, pageSize: pageSize)
        }.value
        guard !Task.isCancelled else { return }
        let target = anchor.map { result.page(for: $0.section, offset: $0.offset) } ?? 0
        let opening = typeset == nil
        for mark in library.state.bookmarks ?? [] where mark.seriesID == series?.id {
            if let offset = mark.offset, let quote = mark.highlightText { result.applyHighlight(section: mark.section ?? 0, offset: offset, quote: quote) }
        }
        typeset = result
        page = target
        if opening, result.pages.indices.contains(target), let series {
            let section = result.pages[target].section
            if let part = series.chapters[safe: section] {
                library.record(part, page: target - result.sectionStarts[section], count: max(1, result.pagesIn(section: section)))
            }
        }
        if typeset != nil, chrome {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { chrome = false }
        }
    }

    private func sectionTitle(_ index: Int) -> String {
        if let title = document?.sections[safe: index]?.title, !title.isEmpty { return title }
        return series?.chapters[safe: index]?.title ?? "Part \(index + 1)"
    }

    // MARK: Reading

    private func tapped(at x: CGFloat) {
        if x < 0.3 { chrome = false; pager.turn(forward: false) }
        else if x > 0.7 { chrome = false; pager.turn(forward: true) }
        else { chrome.toggle() }
    }
    private func pageChanged(from old: Int, to new: Int) {
        logTime()
        guard let typeset, typeset.pages.indices.contains(new), let series else { return }
        let ref = typeset.pages[new]
        library.setBookPosition(BookPosition(section: ref.section, offset: ref.range.location), for: series.id)
        guard let part = series.chapters[safe: ref.section] else { return }
        let inSection = new - typeset.sectionStarts[ref.section]
        let count = typeset.pagesIn(section: ref.section)
        // Turning the page out of a part marks it read (jumps from the contents list or the slider don't).
        if old >= 0, new > old, new - old <= 2, typeset.pages.indices.contains(old), typeset.pages[old].section < ref.section,
           let previous = series.chapters[safe: typeset.pages[old].section] {
            library.record(previous, page: max(0, typeset.pagesIn(section: typeset.pages[old].section) - 1),
                           count: typeset.pagesIn(section: typeset.pages[old].section), completed: true)
        }
        // Reaching a part's last page finishes it.
        library.record(part, page: inSection, count: max(1, count), completed: inSection >= count - 1)
    }
    private func logTime() {
        let now = Date()
        library.logReading(seconds: min(300, now.timeIntervalSince(lastActivity)))
        lastActivity = now
    }

    // MARK: Bookmarks

    private var bookmarkHere: Bookmark? {
        guard let typeset, typeset.pages.indices.contains(page), let series else { return nil }
        let ref = typeset.pages[page]
        return (library.state.bookmarks ?? []).first { mark in
            mark.seriesID == series.id && mark.section == ref.section
                && (mark.offset ?? -1) >= ref.range.location && (mark.offset ?? -1) < ref.range.location + max(1, ref.range.length)
        }
    }
    private func toggleBookmark() {
        if let existing = bookmarkHere { library.removeBookmark(existing); return }
        guard let typeset, typeset.pages.indices.contains(page), let series else { return }
        let ref = typeset.pages[page]
        guard let part = series.chapters[safe: ref.section] else { return }
        library.addBookmark(Bookmark(seriesID: series.id, chapterID: part.id, chapterTitle: sectionTitle(ref.section),
                                     page: page, pageCount: typeset.pages.count, offset: ref.range.location, section: ref.section))
    }

    // MARK: Controls

    @ViewBuilder private func controls(pages: Int) -> some View {
        let ink = Color(theme.text)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close book")
                VStack(alignment: .leading, spacing: 1) {
                    Text(series?.title ?? document?.title ?? "").font(.subheadline.weight(.bold)).lineLimit(1)
                    if let typeset, typeset.pages.indices.contains(page) {
                        Text(sectionTitle(typeset.pages[page].section)).font(.caption).foregroundStyle(ink.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { toggleBookmark() } label: {
                    Image(systemName: bookmarkHere == nil ? "bookmark" : "bookmark.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel(bookmarkHere == nil ? "Bookmark this page" : "Remove bookmark").disabled(typeset == nil)
                Menu {
                    Button("Contents") { contents = true }
                    Button("Find or highlight a passage") { passageTools = true }
                    if let typeset, let ref = typeset.pages[safe: page] {
                        Button("Read aloud from here") {
                            speaker.start([(typeset.sections[ref.section].string as NSString).substring(from: ref.range.location)])
                        }
                    }
                    Button("Stop reading aloud") { speaker.stop() }
                    if let from = beforeSearch, let typeset {
                        Button("Return to previous passage") { page = typeset.page(for: from.section, offset: from.range.location); beforeSearch = nil }
                    }
                } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                    .accessibilityLabel("Contents").disabled(typeset == nil)
                Button { settings = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                    .accessibilityLabel("Text and page settings")
            }
            .font(.title3)
            .padding(.horizontal, 6)
            .background(.ultraThinMaterial)
            Spacer(minLength: 0)
            if let typeset, pages > 0 {
                let section = typeset.pages.indices.contains(page) ? typeset.pages[page].section : 0
                let left = max(0, typeset.sectionStarts[section] + typeset.pagesIn(section: section) - 1 - page)
                VStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(page) }, set: { page = Int($0.rounded()) }),
                           in: 0...Double(max(1, pages - 1)), step: 1)
                        .tint(Eclipse.accent)
                        .accessibilityLabel("Page position")
                    HStack {
                        Text("Page \(page + 1) of \(pages)").monospacedDigit()
                        Spacer()
                        Text(left == 0 ? "Last page of this part" : "\(left) page\(left == 1 ? "" : "s") left in this part")
                    }
                    .font(.caption).foregroundStyle(ink.opacity(0.65))
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .foregroundStyle(ink)
        .transition(.opacity)
    }
}


/// Aa: paper colour, typeface, size, spacing, margins, justification and page turn.
struct BookSettingsSheet: View {
    @Binding var fontRaw: String
    @Binding var size: Double
    @Binding var spacing: Double
    @Binding var margin: Int
    @Binding var justify: Bool
    @Binding var themeRaw: String
    @Binding var curl: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ForEach(BookTheme.allCases) { theme in
                            Button { themeRaw = theme.rawValue } label: {
                                VStack(spacing: 6) {
                                    Text("Aa").font(.system(.title3, design: .serif).weight(.semibold))
                                        .foregroundStyle(Color(theme.text))
                                        .frame(width: 54, height: 54)
                                        .background(Color(theme.background), in: Circle())
                                        .overlay(Circle().strokeBorder(themeRaw == theme.rawValue ? Eclipse.highlight : Color.white.opacity(0.15),
                                                                       lineWidth: themeRaw == theme.rawValue ? 3 : 1))
                                    Text(theme.title).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Text") {
                    Picker("Typeface", selection: $fontRaw) {
                        ForEach(BookFont.allCases) { font in
                            Text(font.title).font(Font(font.font(17) as CTFont)).tag(font.rawValue)
                        }
                    }
                    Stepper(value: $size, in: 13...34, step: 1) {
                        LabeledContent("Size", value: "\(Int(size)) pt")
                    }
                    Picker("Line spacing", selection: $spacing) {
                        Text("Tight").tag(1.2)
                        Text("Normal").tag(1.4)
                        Text("Loose").tag(1.65)
                    }.pickerStyle(.segmented)
                    Picker("Margins", selection: $margin) {
                        Text("Narrow").tag(0)
                        Text("Normal").tag(1)
                        Text("Wide").tag(2)
                    }.pickerStyle(.segmented)
                    Toggle("Justify and hyphenate", isOn: $justify)
                }
                Section {
                    Toggle("Paper page curl", isOn: $curl)
                } footer: {
                    Text("Curl turns pages like paper, with two pages side by side in landscape. Off slides them instead.")
                }
            }
            .navigationTitle("Text & pages").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct BookContentsSheet: View {
    let titles: [String]
    let starts: [Int]
    let current: Int
    let pick: (Int) -> Void
    var body: some View {
        NavigationStack {
            List(titles.indices, id: \.self) { index in
                Button { pick(index) } label: {
                    HStack {
                        Text(titles[index]).font(index == current ? .body.weight(.bold) : .body).lineLimit(2)
                            .foregroundStyle(index == current ? Eclipse.highlight : .primary)
                        Spacer()
                        Text("\(starts[safe: index].map { $0 + 1 } ?? 0)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
        }
    }
}
