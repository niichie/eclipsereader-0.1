import Foundation

// MARK: - Book model

/// A stretch of text with one style.
public struct BookRun: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var mono = false
    public var small = false
    public init(text: String, bold: Bool = false, italic: Bool = false, mono: Bool = false, small: Bool = false) {
        self.text = text; self.bold = bold; self.italic = italic; self.mono = mono; self.small = small
    }
}

/// One block of a book: a paragraph, a heading, a picture…
public enum BookBlock: Sendable, Equatable {
    case heading(level: Int, runs: [BookRun])
    case paragraph(runs: [BookRun])
    case quote(runs: [BookRun])
    case centered(runs: [BookRun])
    case preformatted(String)
    case listItem(runs: [BookRun], marker: String)
    /// A picture inside the book (a path in the EPUB, or an id for embedded images).
    case image(path: String)
    case rule
}

public struct BookSection: Sendable {
    public var title: String?
    public var blocks: [BookBlock]
    public init(title: String?, blocks: [BookBlock]) { self.title = title; self.blocks = blocks }
}

/// A whole book, read from any supported format.
public struct BookDocument: Sendable {
    public var title: String
    public var author: String?
    public var language: String?
    public var isbn: String?
    public var summary: String?
    /// Cover image bytes, when the book carries one.
    public var cover: Data?
    public var sections: [BookSection]
    /// Images embedded in the file itself (FB2, MOBI, DOCX), by the id used in `.image(path:)`.
    public var images: [String: Data]
    public init(title: String, author: String? = nil, language: String? = nil, isbn: String? = nil, summary: String? = nil,
                cover: Data? = nil, sections: [BookSection], images: [String: Data] = [:]) {
        self.title = title; self.author = author; self.language = language; self.isbn = isbn; self.summary = summary
        self.cover = cover; self.sections = sections; self.images = images
    }
}

public enum BookFormat: String, Sendable, CaseIterable {
    case epub, mobi, fb2, txt, html, docx, odt, rtf
    /// Formats read as reflowing text (PDF and CBZ stay in the page reader).
    public static func from(fileExtension ext: String) -> BookFormat? {
        switch ext.lowercased() {
        case "epub", "kepub": .epub
        case "mobi", "azw", "azw3", "prc", "kf8": .mobi
        case "fb2": .fb2
        case "txt", "text", "md", "markdown": .txt
        case "html", "htm", "xhtml": .html
        case "docx": .docx
        case "odt": .odt
        case "rtf": .rtf
        default: nil
        }
    }
}

public enum BookReaderError: LocalizedError, Sendable {
    case unreadable(String)
    public var errorDescription: String? { switch self { case .unreadable(let why): why } }
}

// MARK: - Reading files

public enum BookReader {
    /// Reads a book file. RTF is read by the app (it needs the system's RTF importer).
    public static func read(_ file: URL, format: BookFormat) throws -> BookDocument {
        switch format {
        case .epub: return try EPUBReader.read(file)
        case .mobi: return try MOBIReader.read(try Data(contentsOf: file), name: file.deletingPathExtension().lastPathComponent)
        case .fb2: return try FB2Reader.read(try Data(contentsOf: file), name: file.deletingPathExtension().lastPathComponent)
        case .txt: return PlainTextReader.read(try Data(contentsOf: file), name: file.deletingPathExtension().lastPathComponent)
        case .html:
            let html = BookText.decode(try Data(contentsOf: file))
            let blocks = MarkupReader.blocks(html, base: "")
            let title = LinkedSource.firstMatch(#"(?is)<title[^>]*>(.*?)</title>"#, html).map(BookText.plain)
            return BookDocument(title: title ?? file.deletingPathExtension().lastPathComponent,
                                sections: MarkupReader.splitByHeadings(blocks))
        case .docx: return try OfficeReader.docx(file)
        case .odt: return try OfficeReader.odt(file)
        case .rtf: throw BookReaderError.unreadable("RTF is opened by the app.")
        }
    }
    /// A one-line title for a file name like "Pierce Brown - Red Rising (2014).epub".
    public static func niceName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: #"\s*\(\d{4}\)\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Text helpers

enum BookText {
    /// Bytes to text: BOM, UTF-8, then Windows-1252.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) ?? "" }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) ?? "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "shy": "\u{00AD}",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·", "bull": "•", "times": "×", "divide": "÷", "para": "¶", "sect": "§",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "aring": "å",
        "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï", "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "otilde": "õ",
        "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü", "ntilde": "ñ", "ccedil": "ç", "szlig": "ß", "aelig": "æ", "oelig": "œ",
        "Eacute": "É", "Aacute": "Á", "Oacute": "Ó", "Uacute": "Ú", "Ntilde": "Ñ", "Ccedil": "Ç", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü",
        "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "zwnj": "", "zwj": "", "lsaquo": "‹", "rsaquo": "›", "dagger": "†",
        "Dagger": "‡", "prime": "′", "Prime": "″", "frac12": "½", "frac14": "¼", "frac34": "¾", "pound": "£", "euro": "€", "yen": "¥", "cent": "¢",
    ]
    static func entities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = s[s.index(after: i)..<semi]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[String(name)]
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
    static func plain(_ html: String) -> String {
        entities(html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Resolves `href` against the directory of `base` ("OEBPS/Text/ch1.xhtml" + "../Images/a.jpg").
    static func resolve(_ href: String, from base: String) -> String {
        let clean = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
        if clean.hasPrefix("/") { return String(clean.dropFirst()) }
        var parts = base.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        for piece in clean.split(separator: "/", omittingEmptySubsequences: false) {
            if piece == ".." { if !parts.isEmpty { parts.removeLast() } } else if piece != "." && !piece.isEmpty { parts.append(String(piece)) }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - HTML / XHTML

/// Turns (X)HTML into book blocks: paragraphs, headings, quotes, lists, pictures, with bold,
/// italic, small caps and monospace kept. Layout CSS is ignored so every book reads in the
/// reader's own typography.
public enum MarkupReader {
    static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "section", "article",
                                         "header", "footer", "aside", "figure", "figcaption", "dd", "dt", "tr", "td", "th", "table", "ul", "ol",
                                         "body", "nav", "main", "hr", "address", "center", "dl"]
    public static func blocks(_ html: String, base: String) -> [BookBlock] {
        var body = html
        if let range = html.range(of: #"(?is)<body[^>]*>"#, options: .regularExpression) { body = String(html[range.upperBound...]) }
        body = body.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style|head|title|svg:title)\b[^>]*>.*?</\1\s*>"#,
                                         with: "", options: .regularExpression)
        var blocks: [BookBlock] = []
        var runs: [BookRun] = []
        struct Open { let name: String; let bold: Bool; let italic: Bool; let mono: Bool; let small: Bool; let centered: Bool }
        var stack: [Open] = []
        var bold = 0, italic = 0, mono = 0, small = 0
        var heading = 0, quote = 0, pre = 0, center = 0
        var listMarker: String?
        var orderedCounters: [Int] = []

        func flush() {
            var cleaned = runs
            // Trim leading/trailing whitespace of the whole block.
            while let first = cleaned.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cleaned.removeFirst() }
            while let last = cleaned.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cleaned.removeLast() }
            if !cleaned.isEmpty {
                cleaned[0].text = String(cleaned[0].text.drop(while: { $0 == " " || $0 == "\n" }))
                let n = cleaned.count - 1
                cleaned[n].text = String(cleaned[n].text.reversed().drop(while: { $0 == " " || $0 == "\n" }).reversed())
            }
            runs = []
            guard cleaned.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
            if pre > 0 { blocks.append(.preformatted(cleaned.map(\.text).joined())); return }
            if heading > 0 { blocks.append(.heading(level: heading, runs: cleaned)); return }
            if let marker = listMarker { blocks.append(.listItem(runs: cleaned, marker: marker)); listMarker = nil; return }
            if quote > 0 { blocks.append(.quote(runs: cleaned)); return }
            if center > 0 { blocks.append(.centered(runs: cleaned)); return }
            blocks.append(.paragraph(runs: cleaned))
        }
        func addText(_ raw: String) {
            var text = BookText.entities(raw)
            if pre == 0 {
                text = text.replacingOccurrences(of: #"[ \t\r\n\f]+"#, with: " ", options: .regularExpression)
                if (runs.last?.text.hasSuffix(" ") ?? true) || (runs.last?.text.hasSuffix("\n") ?? false) {
                    if text.hasPrefix(" ") { text.removeFirst() }
                }
            }
            guard !text.isEmpty else { return }
            let run = BookRun(text: text, bold: bold > 0 || heading > 0, italic: italic > 0, mono: mono > 0 || pre > 0, small: small > 0)
            if var last = runs.last, last.bold == run.bold, last.italic == run.italic, last.mono == run.mono, last.small == run.small {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }
        let tokenizer = try? NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9:_-]*)([^>]*?)(/?)>|([^<]+)"#)
        let ns = body as NSString
        tokenizer?.enumerateMatches(in: body, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range(at: 5).location != NSNotFound {
                addText(ns.substring(with: match.range(at: 5)))
                return
            }
            let closing = match.range(at: 1).length > 0
            let name = ns.substring(with: match.range(at: 2)).lowercased().replacingOccurrences(of: "svg:", with: "")
            let attributes = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : ""
            let selfClosing = match.range(at: 4).length > 0
            let lowerAttributes = attributes.lowercased()
            if closing {
                // Finish the block in its own style first, then close the element.
                if blockTags.contains(name) { flush() }
                if let i = stack.lastIndex(where: { $0.name == name }) {
                    for open in stack[i...].reversed() {
                        if open.bold { bold -= 1 }; if open.italic { italic -= 1 }; if open.mono { mono -= 1 }; if open.small { small -= 1 }
                        if open.centered { center = max(0, center - 1) }
                    }
                    stack.removeSubrange(i...)
                }
                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6": heading = 0
                case "blockquote": quote = max(0, quote - 1)
                case "pre": pre = max(0, pre - 1)
                case "ol": if !orderedCounters.isEmpty { orderedCounters.removeLast() }
                default: break
                }
                return
            }
            switch name {
            case "br":
                if pre > 0 { addText("\n") } else { runs.append(BookRun(text: "\n")) }
                return
            case "hr":
                flush(); blocks.append(.rule); return
            case "img", "image":
                flush()
                let source = LinkedSource.firstMatch(#"(?i)(?:src|xlink:href|href)\s*=\s*["']([^"']+)["']"#, attributes)
                if let source, !source.hasPrefix("data:") { blocks.append(.image(path: BookText.resolve(source, from: base))) }
                return
            default: break
            }
            if blockTags.contains(name) { flush() }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6": heading = Int(name.dropFirst()) ?? 2
            case "blockquote": quote += 1
            case "pre": pre += 1
            case "ol": orderedCounters.append(0)
            case "ul": break
            case "li":
                if !orderedCounters.isEmpty {
                    orderedCounters[orderedCounters.count - 1] += 1
                    listMarker = "\(orderedCounters[orderedCounters.count - 1])."
                } else { listMarker = "•" }
            default: break
            }
            if selfClosing { return }
            let isCentered = name == "center" || (["p", "div"].contains(name) && lowerAttributes.contains("center"))
            if isCentered { center += 1 }
            let style = lowerAttributes
            let isBold = ["b", "strong"].contains(name) || style.contains("font-weight:bold") || style.contains("font-weight: bold")
                || style.contains("bold")
            let isItalic = ["i", "em", "cite", "var", "dfn"].contains(name) || style.contains("italic")
            let isMono = ["code", "tt", "kbd", "samp"].contains(name)
            let isSmall = ["small", "sub", "sup"].contains(name) || style.contains("small-caps") || style.contains("smallcaps")
            if isBold { bold += 1 }; if isItalic { italic += 1 }; if isMono { mono += 1 }; if isSmall { small += 1 }
            stack.append(Open(name: name, bold: isBold, italic: isItalic, mono: isMono, small: isSmall, centered: isCentered))
        }
        flush()
        return blocks
    }

    /// Splits one long document into sections at its top headings (for TXT/HTML/DOCX).
    public static func splitByHeadings(_ blocks: [BookBlock]) -> [BookSection] {
        let top = blocks.compactMap { block -> Int? in if case .heading(let level, _) = block { return level } else { return nil } }.min()
        guard let top else { return [BookSection(title: nil, blocks: blocks)] }
        var sections: [BookSection] = []
        var current = BookSection(title: nil, blocks: [])
        for block in blocks {
            if case .heading(let level, let runs) = block, level == top, !current.blocks.isEmpty {
                sections.append(current)
                current = BookSection(title: runs.map(\.text).joined(), blocks: [block])
                continue
            }
            if case .heading(let level, let runs) = block, level == top, current.title == nil { current.title = runs.map(\.text).joined() }
            current.blocks.append(block)
        }
        if !current.blocks.isEmpty { sections.append(current) }
        return sections
    }
}

// MARK: - EPUB

enum EPUBReader {
    static func read(_ file: URL) throws -> BookDocument {
        let entries = try ZipIndex.read(file, maxEntry: 64 * 1024 * 1024)
        var byPath: [String: BookManifest.Entry] = [:]
        for entry in entries { byPath[entry.path] = entry; byPath[entry.path.lowercased()] = entry }
        func data(_ path: String) -> Data? {
            guard let entry = byPath[path] ?? byPath[path.lowercased()] else { return nil }
            return try? ZipIndex.extract(entry, from: file)
        }
        func text(_ path: String) -> String? { data(path).map(BookText.decode) }
        guard let container = text("META-INF/container.xml"),
              let opfPath = LinkedSource.firstMatch(#"(?is)<rootfile[^>]+full-path=["']([^"']+)["']"#, container).map({ BookText.entities($0) }),
              let opf = text(opfPath) else {
            throw BookReaderError.unreadable("This EPUB is damaged: its table of contents is missing.")
        }
        if byPath["META-INF/encryption.xml"] != nil, let encryption = text("META-INF/encryption.xml"),
           encryption.contains("EncryptedData"), !encryption.contains("http://www.idpf.org/2008/embedding") {
            throw BookReaderError.unreadable("This EPUB is protected with DRM, so it can only be opened in the app it was bought in.")
        }
        func meta(_ tag: String) -> String? {
            LinkedSource.firstMatch(#"(?is)<dc:\#(tag)\b[^>]*>(.*?)</dc:\#(tag)>"#, opf).map(BookText.plain).flatMap { $0.isEmpty ? nil : $0 }
        }
        struct Item { let href: String; let type: String; let properties: String }
        var manifest: [String: Item] = [:]
        for tag in ReadBerserkParser.tags("item", opf) {
            let fields = ReadBerserkParser.attributes(tag)
            guard let id = fields["id"], let href = fields["href"] else { continue }
            manifest[id] = Item(href: BookText.resolve(BookText.entities(href), from: opfPath), type: fields["media-type"] ?? "", properties: fields["properties"] ?? "")
        }
        var spine: [String] = []
        for tag in ReadBerserkParser.tags("itemref", opf) {
            let fields = ReadBerserkParser.attributes(tag)
            guard let id = fields["idref"], let item = manifest[id], fields["linear"] != "no" || spine.isEmpty else { continue }
            if item.type.contains("html") || item.href.lowercased().hasSuffix("htm") || item.href.lowercased().hasSuffix("html") { spine.append(item.href) }
        }
        guard !spine.isEmpty else { throw BookReaderError.unreadable("This EPUB has no readable chapters.") }

        // Table of contents: EPUB 3 nav, else EPUB 2 NCX. Maps chapter files to their titles.
        var tocTitles: [String: String] = [:]
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }), let html = text(nav.href) {
            let toc = LinkedSource.firstMatch(#"(?is)<nav[^>]*toc[^>]*>(.*?)</nav>"#, html) ?? html
            for m in LinkedSource.matches(#"(?is)<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>"#, toc) {
                let path = BookText.resolve(BookText.entities(m[0]), from: nav.href)
                if tocTitles[path] == nil { tocTitles[path] = BookText.plain(m[1]) }
            }
        }
        if tocTitles.isEmpty, let ncx = manifest.values.first(where: { $0.type.contains("dtbncx") }), let xml = text(ncx.href) {
            for m in LinkedSource.matches(#"(?is)<navLabel>\s*<text>(.*?)</text>\s*</navLabel>\s*<content[^>]+src=["']([^"']+)["']"#, xml) {
                let path = BookText.resolve(BookText.entities(m[1]), from: ncx.href)
                if tocTitles[path] == nil { tocTitles[path] = BookText.plain(m[0]) }
            }
        }
        var sections: [BookSection] = []
        for href in spine {
            guard let html = text(href) else { continue }
            let blocks = MarkupReader.blocks(html, base: href)
            guard !blocks.isEmpty else { continue }
            let heading = blocks.lazy.compactMap { block -> String? in
                if case .heading(_, let runs) = block { return runs.map(\.text).joined() } else { return nil }
            }.first
            sections.append(BookSection(title: tocTitles[href] ?? heading, blocks: blocks))
        }
        // Cover: EPUB 3 cover-image, EPUB 2 <meta name="cover">, or an image named like a cover.
        var coverPath = manifest.values.first(where: { $0.properties.contains("cover-image") })?.href
        if coverPath == nil, let id = LinkedSource.firstMatch(#"(?is)<meta[^>]+name=["']cover["'][^>]+content=["']([^"']+)["']"#, opf)
            ?? LinkedSource.firstMatch(#"(?is)<meta[^>]+content=["']([^"']+)["'][^>]+name=["']cover["']"#, opf) {
            coverPath = manifest[id]?.href
        }
        if coverPath == nil {
            coverPath = manifest.values.first(where: { $0.type.hasPrefix("image/") && $0.href.lowercased().contains("cover") })?.href
        }
        let identifier = LinkedSource.matches(#"(?is)<dc:identifier\b[^>]*>(.*?)</dc:identifier>"#, opf).map { BookText.plain($0[0]) }
        let isbn = identifier.lazy.map { $0.replacingOccurrences(of: #"[^0-9Xx]"#, with: "", options: .regularExpression) }
            .first { $0.count == 13 || $0.count == 10 }
        return BookDocument(title: meta("title") ?? BookReader.niceName(file.deletingPathExtension().lastPathComponent),
                            author: meta("creator"), language: meta("language"), isbn: isbn,
                            summary: meta("description"), cover: coverPath.flatMap(data), sections: sections)
    }
}

// MARK: - Plain text

enum PlainTextReader {
    static func read(_ data: Data, name: String) -> BookDocument {
        let text = BookText.decode(data).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        let hasBlankLines = lines.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Hard-wrapped text (Project Gutenberg): paragraphs are separated by blank lines.
        var paragraphs: [String] = []
        if hasBlankLines {
            var current: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
                } else { current.append(trimmed) }
            }
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        } else {
            paragraphs = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let heading = try? NSRegularExpression(pattern: #"^(chapter|part|book|prologue|epilogue|interlude|act)\b[^.!?]{0,60}$|^[IVXLC]{1,7}\.?$|^\d{1,3}\.?$"#,
                                               options: [.caseInsensitive])
        var blocks: [BookBlock] = []
        for paragraph in paragraphs {
            let range = NSRange(paragraph.startIndex..., in: paragraph)
            if paragraph.count <= 70, heading?.firstMatch(in: paragraph, range: range) != nil {
                blocks.append(.heading(level: 2, runs: [BookRun(text: paragraph, bold: true)]))
            } else {
                blocks.append(.paragraph(runs: [BookRun(text: paragraph)]))
            }
        }
        // Project Gutenberg header/footer licence text is kept out of the story.
        if let start = blocks.firstIndex(where: { block in
            if case .paragraph(let runs) = block { return runs.first?.text.contains("*** START OF") == true } else { return false }
        }) { blocks.removeFirst(start + 1) }
        if let end = blocks.firstIndex(where: { block in
            if case .paragraph(let runs) = block { return runs.first?.text.contains("*** END OF") == true } else { return false }
        }) { blocks.removeSubrange(end...) }
        return BookDocument(title: BookReader.niceName(name), sections: MarkupReader.splitByHeadings(blocks))
    }
}

// MARK: - FictionBook (FB2)

enum FB2Reader {
    static func read(_ data: Data, name: String) throws -> BookDocument {
        let xml = BookText.decode(data)
        guard xml.contains("<FictionBook") || xml.contains("<body") else { throw BookReaderError.unreadable("This FB2 file is damaged.") }
        var images: [String: Data] = [:]
        for m in LinkedSource.matches(#"(?is)<binary[^>]+id=["']([^"']+)["'][^>]*>(.*?)</binary>"#, xml) {
            if let bytes = Data(base64Encoded: m[1], options: .ignoreUnknownCharacters) { images["fb2:" + m[0]] = bytes }
        }
        let titleInfo = LinkedSource.firstMatch(#"(?is)<title-info>(.*?)</title-info>"#, xml) ?? ""
        let title = LinkedSource.firstMatch(#"(?is)<book-title>(.*?)</book-title>"#, titleInfo).map(BookText.plain)
        let first = LinkedSource.firstMatch(#"(?is)<first-name>(.*?)</first-name>"#, titleInfo).map(BookText.plain)
        let last = LinkedSource.firstMatch(#"(?is)<last-name>(.*?)</last-name>"#, titleInfo).map(BookText.plain)
        let author = [first, last].compactMap { $0 }.joined(separator: " ")
        let annotation = LinkedSource.firstMatch(#"(?is)<annotation>(.*?)</annotation>"#, titleInfo).map(BookText.plain)
        let coverID = LinkedSource.firstMatch(#"(?is)<coverpage>.*?href=["']#([^"']+)["']"#, titleInfo)
        guard var body = LinkedSource.firstMatch(#"(?is)<body(?![^>]*name=["']notes["'])[^>]*>(.*?)</body>"#, xml) else {
            throw BookReaderError.unreadable("This FB2 file has no text.")
        }
        // FB2 tags in HTML terms, so the same reader handles them.
        let map: [(String, String)] = [
            (#"(?is)<title>"#, "<h2>"), (#"(?is)</title>"#, "</h2>"), (#"(?is)<subtitle>"#, "<h3>"), (#"(?is)</subtitle>"#, "</h3>"),
            (#"(?is)<emphasis>"#, "<i>"), (#"(?is)</emphasis>"#, "</i>"), (#"(?is)<strong>"#, "<b>"), (#"(?is)</strong>"#, "</b>"),
            (#"(?is)<(epigraph|cite)>"#, "<blockquote>"), (#"(?is)</(epigraph|cite)>"#, "</blockquote>"),
            (#"(?is)<v>"#, "<p>"), (#"(?is)</v>"#, "</p>"), (#"(?is)<empty-line\s*/>"#, ""), (#"(?is)<text-author>"#, "<p><i>"), (#"(?is)</text-author>"#, "</i></p>"),
            (#"(?is)<image[^>]+href=["']#([^"']+)["'][^>]*/?>"#, #"<img src="fb2:$1"/>"#),
        ]
        for (pattern, replacement) in map { body = body.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        // Top-level sections become chapters.
        var sections: [BookSection] = []
        var depth = 0
        var current = ""
        let tokens = LinkedSource.matches(#"(?is)(<section\b[^>]*>|</section>|[^<]+|<[^>]+>)"#, body).map { $0[0] }
        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("<section") {
                if depth == 0, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sections.append(section(current)); current = ""
                }
                depth += 1
                continue
            }
            if lower == "</section>" {
                depth -= 1
                if depth == 0 { sections.append(section(current)); current = "" }
                continue
            }
            current += token
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(section(current)) }
        sections = sections.filter { !$0.blocks.isEmpty }
        return BookDocument(title: title ?? BookReader.niceName(name), author: author.isEmpty ? nil : author, summary: annotation,
                            cover: coverID.flatMap { images["fb2:" + $0] }, sections: sections, images: images)
    }
    private static func section(_ html: String) -> BookSection {
        let blocks = MarkupReader.blocks("<body>" + html + "</body>", base: "").map { block -> BookBlock in
            if case .image(let path) = block, !path.hasPrefix("fb2:") { return .image(path: "fb2:" + path.replacingOccurrences(of: "fb2:", with: "")) }
            return block
        }
        let title = blocks.lazy.compactMap { block -> String? in
            if case .heading(_, let runs) = block { return runs.map(\.text).joined() } else { return nil }
        }.first
        return BookSection(title: title, blocks: blocks)
    }
}

// MARK: - Word (DOCX) and OpenDocument (ODT)

enum OfficeReader {
    private static func zipText(_ file: URL, _ path: String) throws -> String {
        let entries = try ZipIndex.read(file, maxEntry: 64 * 1024 * 1024)
        guard let entry = entries.first(where: { $0.path == path }) else { throw BookReaderError.unreadable("This document is damaged.") }
        return BookText.decode(try ZipIndex.extract(entry, from: file))
    }
    static func docx(_ file: URL) throws -> BookDocument {
        let xml = try zipText(file, "word/document.xml")
        var html = "<body>"
        for p in LinkedSource.matches(#"(?is)(<w:p[ >].*?</w:p>)"#, xml) {
            let paragraph = p[0]
            let style = LinkedSource.firstMatch(#"<w:pStyle w:val="([^"]+)""#, paragraph)?.lowercased() ?? ""
            var level = 0
            if style.hasPrefix("heading"), let n = Int(style.dropFirst(7)) { level = min(6, max(1, n)) }
            if style == "title" { level = 1 }
            var inner = ""
            for r in LinkedSource.matches(#"(?is)(<w:r[ >].*?</w:r>)"#, paragraph) {
                let run = r[0]
                let bold = run.range(of: #"<w:b(\s*/>|\s+w:val="(1|true)"\s*/>)"#, options: .regularExpression) != nil
                let italic = run.range(of: #"<w:i(\s*/>|\s+w:val="(1|true)"\s*/>)"#, options: .regularExpression) != nil
                var text = LinkedSource.matches(#"(?is)<w:t(?:\s[^>]*)?>(.*?)</w:t>"#, run).map { $0[0] }.joined()
                if run.contains("<w:tab/>") { text = " " + text }
                if run.contains("<w:br/>") { text += "<br/>" }
                if bold { text = "<b>\(text)</b>" }
                if italic { text = "<i>\(text)</i>" }
                inner += text
            }
            html += level > 0 ? "<h\(level)>\(inner)</h\(level)>" : "<p>\(inner)</p>"
        }
        html += "</body>"
        let core = (try? zipText(file, "docProps/core.xml")) ?? ""
        let title = LinkedSource.firstMatch(#"(?is)<dc:title>(.*?)</dc:title>"#, core).map(BookText.plain).flatMap { $0.isEmpty ? nil : $0 }
        let author = LinkedSource.firstMatch(#"(?is)<dc:creator>(.*?)</dc:creator>"#, core).map(BookText.plain).flatMap { $0.isEmpty ? nil : $0 }
        return BookDocument(title: title ?? BookReader.niceName(file.deletingPathExtension().lastPathComponent), author: author,
                            sections: MarkupReader.splitByHeadings(MarkupReader.blocks(html, base: "")))
    }
    static func odt(_ file: URL) throws -> BookDocument {
        var xml = try zipText(file, "content.xml")
        let map: [(String, String)] = [
            (#"(?is)<text:h[^>]*text:outline-level="(\d)"[^>]*>"#, "<h$1>"), (#"(?is)</text:h>"#, "</h2>"),
            (#"(?is)<text:p\b[^>]*/>"#, ""), (#"(?is)<text:p\b[^>]*>"#, "<p>"), (#"(?is)</text:p>"#, "</p>"),
            (#"(?is)<text:line-break\s*/>"#, "<br/>"), (#"(?is)<text:tab\s*/>"#, " "), (#"(?is)<text:s(\s+[^>]*)?/>"#, " "),
            (#"(?is)<text:list-item>"#, "<li>"), (#"(?is)</text:list-item>"#, "</li>"),
        ]
        for (pattern, replacement) in map { xml = xml.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        // Headings were opened as <hN> but closed as </h2>: let the reader close any heading.
        xml = xml.replacingOccurrences(of: "</h2>", with: "</h1></h2></h3></h4></h5></h6>")
        let body = LinkedSource.firstMatch(#"(?is)<office:text[^>]*>(.*?)</office:text>"#, xml) ?? xml
        return BookDocument(title: BookReader.niceName(file.deletingPathExtension().lastPathComponent),
                            sections: MarkupReader.splitByHeadings(MarkupReader.blocks("<body>" + body + "</body>", base: "")))
    }
}

// MARK: - Mobipocket / Kindle (MOBI, AZW, AZW3, PRC)

enum MOBIReader {
    private static func u16(_ d: [UInt8], _ o: Int) -> Int { o + 1 < d.count ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
    private static func u32(_ d: [UInt8], _ o: Int) -> Int { o + 3 < d.count ? Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) : 0 }

    static func read(_ data: Data, name: String) throws -> BookDocument {
        let bytes = [UInt8](data)
        guard bytes.count > 78 else { throw BookReaderError.unreadable("This Kindle file is damaged.") }
        let count = u16(bytes, 76)
        var offsets: [Int] = []
        for i in 0..<count { offsets.append(u32(bytes, 78 + i * 8)) }
        offsets.append(bytes.count)
        func record(_ i: Int) -> [UInt8] {
            guard i + 1 < offsets.count, offsets[i] < offsets[i + 1], offsets[i + 1] <= bytes.count else { return [] }
            return Array(bytes[offsets[i]..<offsets[i + 1]])
        }
        let header = record(0)
        guard header.count >= 16 else { throw BookReaderError.unreadable("This Kindle file is damaged.") }
        let compression = u16(header, 0)
        let textRecords = u16(header, 8)
        if u16(header, 12) != 0 { throw BookReaderError.unreadable("This Kindle book is protected with DRM, so it can only be opened in the Kindle app.") }
        if compression == 17480 {
            throw BookReaderError.unreadable("This Kindle book uses Amazon's own compression. Convert it to EPUB with Calibre (free), then import that.")
        }
        var encoding = String.Encoding.windowsCP1252
        var extraFlags = 0
        var firstImage = Int.max
        var title = BookReader.niceName(name)
        var author: String?
        var coverOffset: Int?
        if header.count > 20, header[16] == 0x4D, header[17] == 0x4F, header[18] == 0x42, header[19] == 0x49 {   // "MOBI"
            let length = u32(header, 20)
            if u32(header, 28) == 65001 { encoding = .utf8 }
            if length >= 0xE4, header.count >= 0xF4 { extraFlags = u16(header, 0xF2) }
            let imageIndex = u32(header, 0x6C)
            if imageIndex > 0 && imageIndex < count { firstImage = imageIndex }
            let nameOffset = u32(header, 84), nameLength = u32(header, 88)
            if nameOffset + nameLength <= header.count, nameLength > 0,
               let full = String(bytes: header[nameOffset..<(nameOffset + nameLength)], encoding: encoding), !full.isEmpty { title = full }
            // EXTH: author (100), title (503), cover (201).
            if u32(header, 0x80) & 0x40 != 0 {
                var p = 16 + length
                if p + 12 <= header.count, header[p] == 0x45, header[p + 1] == 0x58 {
                    let records = u32(header, p + 8)
                    p += 12
                    for _ in 0..<records {
                        let type = u32(header, p), size = u32(header, p + 4)
                        guard size >= 8, p + size <= header.count else { break }
                        let value = Array(header[(p + 8)..<(p + size)])
                        switch type {
                        case 100: author = String(bytes: value, encoding: encoding)
                        case 503: if let t = String(bytes: value, encoding: encoding), !t.isEmpty { title = t }
                        case 201: coverOffset = value.count >= 4 ? u32(value, 0) : nil
                        default: break
                        }
                        p += size
                    }
                }
            }
        }
        // Text records, trailing entries removed, then decompressed.
        var text: [UInt8] = []
        for i in 1...max(1, min(textRecords, count - 1)) {
            var chunk = record(i)
            chunk.removeLast(min(chunk.count, trailingSize(chunk, flags: extraFlags)))
            switch compression {
            case 1: text += chunk
            case 2: text += palmDOC(chunk)
            default: throw BookReaderError.unreadable("This Kindle file uses a compression eclipsereader can't read.")
            }
        }
        var html = String(bytes: text, encoding: encoding) ?? String(decoding: text, as: UTF8.self)
        // Kindle markup to plain HTML: page breaks split chapters, recindex points at image records.
        var images: [String: Data] = [:]
        if firstImage != Int.max {
            for i in firstImage..<count {
                let r = record(i)
                guard r.count > 8 else { continue }
                let isImage = (r[0] == 0xFF && r[1] == 0xD8) || (r[0] == 0x89 && r[1] == 0x50) || (r[0] == 0x47 && r[1] == 0x49)
                if isImage { images["mobi:\(i - firstImage + 1)"] = Data(r) }
            }
        }
        html = html.replacingOccurrences(of: #"(?is)<img[^>]*recindex=["']?0*(\d+)["']?[^>]*>"#, with: #"<img src="mobi:$1"/>"#, options: .regularExpression)
        html = html.replacingOccurrences(of: #"(?is)<img[^>]*kindle:embed:([0-9A-Z]{4})[^>]*>"#, with: "", options: .regularExpression)
        let parts = html.components(separatedBy: "<mbp:pagebreak")
        var sections: [BookSection] = []
        for part in parts {
            let chunk = part.hasPrefix("/>") || part.hasPrefix(">") ? String(part.drop(while: { $0 != ">" }).dropFirst()) : part
            let blocks = MarkupReader.blocks("<body>" + chunk + "</body>", base: "").map { block -> BookBlock in
                if case .image(let path) = block, let n = Int(path.replacingOccurrences(of: "mobi:", with: "")) { return .image(path: "mobi:\(n)") }
                return block
            }
            guard !blocks.isEmpty else { continue }
            let heading = blocks.lazy.compactMap { block -> String? in
                if case .heading(_, let runs) = block { return runs.map(\.text).joined() } else { return nil }
            }.first
            sections.append(BookSection(title: heading, blocks: blocks))
        }
        if sections.count <= 1 { sections = MarkupReader.splitByHeadings(sections.flatMap(\.blocks)) }
        let cover = coverOffset.flatMap { images["mobi:\($0 + 1)"] }
        return BookDocument(title: title, author: author, cover: cover, sections: sections, images: images)
    }

    /// Bytes at the end of a text record that aren't text (Mobipocket "extra data" flags).
    static func trailingSize(_ data: [UInt8], flags: Int) -> Int {
        func entry(_ end: Int) -> Int {
            var result = 0, bitpos = 0, p = end
            while p > 0 {
                let v = Int(data[p - 1])
                result |= (v & 0x7F) << bitpos
                bitpos += 7
                p -= 1
                if v & 0x80 != 0 || bitpos >= 28 { break }
            }
            return result
        }
        var num = 0
        var f = flags >> 1
        while f != 0 {
            if f & 1 != 0, data.count - num > 0 { num += entry(data.count - num) }
            f >>= 1
        }
        if flags & 1 != 0, data.count - num - 1 >= 0 { num += Int(data[data.count - num - 1] & 0x3) + 1 }
        return min(num, data.count)
    }

    /// PalmDOC LZ77 decompression.
    static func palmDOC(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 2)
        var i = 0
        while i < data.count {
            let c = data[i]; i += 1
            switch c {
            case 0x01...0x08:
                let end = min(data.count, i + Int(c))
                out += data[i..<end]; i = end
            case 0x80...0xBF:
                guard i < data.count else { return out }
                let pair = Int(c) << 8 | Int(data[i]); i += 1
                let distance = (pair >> 3) & 0x07FF, length = (pair & 0x07) + 3
                guard distance > 0, distance <= out.count else { continue }
                for _ in 0..<length { out.append(out[out.count - distance]) }
            case 0xC0...0xFF:
                out.append(0x20); out.append(c ^ 0x80)
            default:
                out.append(c)
            }
        }
        return out
    }
}
