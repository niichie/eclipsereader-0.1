import Foundation

/// The app's bundled sources (Resources/DefaultSources.json): ordinary website destinations that appear in
/// Browse after install. They are kept in one editable file rather than spread through the code.
public enum SourceManifest {
    struct File: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
            let url: String
            let category: SourceCategory
            let note: String?
            let native: Bool?
            let style: ReadingStyle?
        }
        let sources: [Entry]
    }
    /// The sources in the file, in order. Entries with a bad address or a repeated id are skipped.
    public static func decode(_ data: Data) throws -> [SavedSite] {
        let file = try JSONDecoder().decode(File.self, from: data)
        var seen = Set<String>()
        return file.sources.compactMap { entry in
            guard seen.insert(entry.id).inserted, let url = URL(string: entry.url), WebLink.publicHTTPS(url) else { return nil }
            return SavedSite(name: entry.name, url: url, category: entry.category, style: entry.style, note: entry.note,
                             bundledID: entry.id, native: entry.native)
        }
    }

    /// Addresses from pasted text or a shared list: one per line (or separated by spaces or commas). "Name — https://…",
    /// "Name | https://…" and Markdown links keep their names; lines starting with # are comments.
    public static func parseList(_ text: String) -> [SavedSite] {
        var found: [SavedSite] = []
        var hosts = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var name: String?
            if let label = LinkedSource.firstMatch(#"^\[([^\]]+)\]\("#, line) { name = label }
            else if let label = LinkedSource.firstMatch(#"^\s*(?:[-*•]\s*)?([^|—–:]+?)\s*(?:—|–|\||: )\s*\S"#, line), !label.contains(".") { name = label }
            let candidates = LinkedSource.matches(#"((?:https?://)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:/[^\s,)\]]*)?)"#, line).map { $0[0] }
            for candidate in candidates {
                guard let url = WebLink.parse(candidate.hasPrefix("http") ? candidate : "https://" + candidate), let host = url.host?.lowercased(),
                      hosts.insert(host.replacingOccurrences(of: "www.", with: "")).inserted else { continue }
                let display = name ?? host.replacingOccurrences(of: "www.", with: "")
                found.append(SavedSite(name: String(display.prefix(60)), url: url))
                name = nil
            }
        }
        return found
    }
}
