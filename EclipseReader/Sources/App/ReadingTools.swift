import SwiftUI
import AVFoundation
import NaturalLanguage

@MainActor
final class PassageSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var utteranceID: ObjectIdentifier?
    override init() { super.init(); synth.delegate = self }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, utteranceID == id else { return }
            play(position + 1)
        }
    }
    private var passages: [String] = []
    @Published private(set) var position = 0
    func start(_ strings: [String], at index: Int = 0) {
        stop()
        passages = strings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        play(index)
    }
    func play(_ index: Int) {
        guard passages.indices.contains(index) else { return }
        synth.stopSpeaking(at: .immediate)
        position = index
        let text = passages[index]
        do {
            let speech = AVSpeechUtterance(string: text)
            if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
                speech.voice = AVSpeechSynthesisVoice(language: language.rawValue)
            }
            utteranceID = ObjectIdentifier(speech)
            synth.speak(speech)
        }
    }
    func stop() { utteranceID = nil; synth.stopSpeaking(at: .immediate); passages = []; position = 0 }
}

/// Uses UTF-16 offsets, matching the book typesetter and persisted bookmarks.
struct PassageTools: View {
    @Environment(\.dismiss) private var dismiss
    let book: TypesetBook
    let page: Int
    let sections: Int
    let title: (Int) -> String
    let jump: (Int, Int) -> Void
    let annotate: (Int, Int, String, String) -> Void
    let speaker: PassageSpeaker
    var searchChapters: ((String) async -> [ChapterHit])? = nil
    var jumpToChapter: ((ChapterHit) -> Void)? = nil
    struct ChapterHit: Identifiable {
        let chapter: Chapter
        let passage: String
        var id: String { chapter.id }
    }
    @State private var otherMatches: [ChapterHit] = []
    @State private var query = ""
    @State private var note = ""
    @State private var selected: Hit?
    @State private var matches: [Hit] = []
    struct Hit: Identifiable, Sendable {
        let section: Int
        let offset: Int
        let text: String
        var id: String { "\(section):\(offset)" }
    }
    nonisolated static func find(_ query: String, in strings: [String], page: BookPageRef) -> [Hit] {
        var hits: [Hit] = []
        for (i, text) in strings.enumerated() where !query.isEmpty || i == page.section {
            let source = text as NSString
            let bounds = query.isEmpty ? NSIntersectionRange(page.range, NSRange(location: 0, length: source.length)) : NSRange(location: 0, length: source.length)
            guard bounds.length > 0 else { continue }
            let excerpt = source.substring(with: bounds) as NSString
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = excerpt as String
            let str = excerpt as String
            tokenizer.enumerateTokens(in: str.startIndex..<str.endIndex) { range, _ in
                let sentence = String(str[range])
                if query.isEmpty || sentence.localizedCaseInsensitiveContains(query) {
                    hits.append(Hit(section: i, offset: bounds.location + NSRange(range, in: str).location, text: sentence))
                }
                return hits.count < 100 && !Task.isCancelled
            }
            if hits.count >= 100 || Task.isCancelled { break }
        }
        return hits
    }
    var body: some View {
        NavigationStack {
            List {
                if matches.isEmpty && otherMatches.isEmpty { Text("No passages found").foregroundStyle(.secondary) }
                ForEach(otherMatches) { hit in
                    Button { jumpToChapter?(hit); dismiss() } label: {
                        VStack(alignment: .leading) {
                            Text(hit.chapter.title).font(.caption)
                            Text(hit.passage).lineLimit(3)
                        }
                    }
                }
                ForEach(matches) { hit in
                    Button { selected = hit } label: {
                        VStack(alignment: .leading) {
                            Text(title(hit.section)).font(.caption).foregroundStyle(.secondary)
                            Text(hit.text).lineLimit(4)
                        }
                    }
                }
            }
            .navigationTitle("Passages")
            .searchable(text: $query, prompt: "Find in text")
            .toolbar { Button("Done") { dismiss() } }
            .task(id: query) {
                otherMatches = []
                guard let ref = book.pages[safe: page] else { return }
                let strings = book.sections.prefix(sections).map(\.string)
                let search = query
                let result = await Task.detached(priority: .userInitiated) { Self.find(search, in: strings, page: ref) }.value
                guard !Task.isCancelled else { return }
                matches = result
                if !search.isEmpty, let searchChapters {
                    let others = await searchChapters(search)
                    if !Task.isCancelled { otherMatches = others }
                }
            }
            .sheet(item: $selected) { hit in
                NavigationStack {
                    Form {
                        Text(hit.text).textSelection(.enabled)
                        Button("Go to passage") { jump(hit.section, hit.offset); dismiss() }
                        Button("Read aloud from here") {
                            let remaining = book.sections[hit.section].string as NSString
                            speaker.start([remaining.substring(from: hit.offset)])
                            dismiss()
                        }
                        TextField("Optional note", text: $note, axis: .vertical)
                        Button("Save highlight") { annotate(hit.section, hit.offset, hit.text, note); note = ""; selected = nil }
                    }.navigationTitle("Selected passage")
                }.presentationDetents([.medium, .large])
            }
        }
    }
}