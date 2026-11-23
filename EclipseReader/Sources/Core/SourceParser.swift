import Foundation

/// Narrow, fail-closed parser for the markup observed on 2026-11-20.
/// Not a general HTML parser. It accepts only source chapter links and pages__img tags.
public enum ReadBerserkParser {
    public static let home = URL(string: "https://readberserk.com/")!
    public static func normalize(_ raw: String, relativeTo base: URL, image: Bool = false) -> URL? {
        guard let url = URL(string: entities(raw).trimmingCharacters(in: .whitespacesAndNewlines),
                            relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        let allowed = image ? ["readberserk.com", "www.readberserk.com", "cdn.readberserk.com"]
                            : ["readberserk.com", "www.readberserk.com"]
        return allowed.contains(url.host?.lowercased() ?? "") ? url : nil
    }
    public static func chapters(in html: String) throws -> [Chapter] {
        var found: [Chapter] = []
        var seen = Set<String>()
        // Table rows carry labels outside their "Read" link.
        for row in captures(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, html) {
            let cells = captures(#"(?is)<td\b[^>]*>(.*?)</td>"#, row)
            guard let first = cells.first else { continue }
            let title = text(first)
            for tag in tags("a", row) {
                if let chapter = chapter(attributes(tag)["href"], title: title,
                                         published: cells.count > 1 ? text(cells[1]) : nil),
                   seen.insert(chapter.id).inserted { found.append(chapter) }
            }
        }
        // Chapter pages expose the same catalog as options, in descending story order.
        if found.isEmpty {
            for match in matches(#"(?is)(<option\b(?:\"[^\"]*\"|'[^']*'|[^'\">])*>)\s*(.*?)</option>"#, html) {
                if let chapter = chapter(attributes(match[0])["value"], title: text(match[1]), published: nil),
                   seen.insert(chapter.id).inserted { found.append(chapter) }
            }
        }
        guard !found.isEmpty else { throw SourceError.unsupportedStructure }
        // Preserve source-defined order, including alphabetic prologue chapters and decimals.
        return Array(found.reversed())
    }
    private static func chapter(_ raw: String?, title: String, published: String?) -> Chapter? {
        guard let raw, let url = normalize(raw, relativeTo: home),
              url.path.hasPrefix("/chapter/"),
              let match = matches(#"(?i)^Berserk\s+Chapter\s+([A-P]0|\d+(?:\.\d+)?)(?:\s*[:–-]\s*.*)?$"#, title).first
        else { return nil }
        return Chapter(url: url, title: title, number: match[0], published: published)
    }
    public static func pages(in html: String, chapterURL: URL) throws -> [MangaPage] {
        var pages: [MangaPage] = []
        var seen = Set<URL>()
        for tag in tags("img", html) {
            let attrs = attributes(tag)
            guard attrs["class"]?.split(whereSeparator: \.isWhitespace).contains("pages__img") == true else { continue }
            guard let raw = attrs["src"], let url = normalize(raw, relativeTo: chapterURL, image: true)
            else { throw SourceError.insecureURL }
            guard seen.insert(url).inserted else { continue }
            pages.append(MangaPage(url: url, label: attrs["alt"] ?? "Page \(pages.count + 1)",
                                   width: attrs["width"].flatMap(Double.init),
                                   height: attrs["height"].flatMap(Double.init)))
        }
        guard !pages.isEmpty else { throw SourceError.unsupportedStructure }
        return pages
    }
    static func tags(_ name: String, _ html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "(?is)<\(name)\\b(?:\"[^\"]*\"|'[^']*'|[^'\">])*>") else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for parts in matches(#"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#, tag) {
            result[parts[0].lowercased()] = entities(parts.dropFirst().first(where: { !$0.isEmpty }) ?? "")
        }
        return result
    }
    static func matches(_ pattern: String, _ string: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = string as NSString
        return re.matches(in: string, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { i in
                match.range(at: i).location == NSNotFound ? "" : ns.substring(with: match.range(at: i))
            }
        }
    }
    static func captures(_ pattern: String, _ string: String) -> [String] { matches(pattern, string).compactMap(\.first) }
    static func text(_ html: String) -> String {
        entities(html.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func entities(_ string: String) -> String {
        var output = string
        let ns = output as NSString
        if let re = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|[0-9]+);"#) {
            for m in re.matches(in: output, range: NSRange(location: 0, length: ns.length)).reversed() {
                let code = ns.substring(with: m.range(at: 1))
                let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = UnicodeScalar(value), let range = Range(m.range, in: output) {
                    output.replaceSubrange(range, with: String(scalar))
                }
            }
        }
        for (from, to) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            output = output.replacingOccurrences(of: from, with: to)
        }
        return output
    }
}
