import SwiftUI
import UIKit
import Vision
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

/// Gives SwiftUI access to the live reader view, for snapshots used by text recognition.
@MainActor
final class ReaderHandle {
    weak var controller: UIViewController?
    func snapshot() -> UIImage? {
        guard let view = controller?.view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = max(2, view.window?.screen.scale ?? 2)
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }
}

/// One recognized speech bubble or caption, in reader-view coordinates.
/// Text and translations are stored separately from the artwork, which is never modified.
struct TextBlock: Identifiable, Equatable, Sendable {
    let id: String
    var rect: CGRect
    var original: String
    var translated: String?
    var confidence: Float
    var showOriginal = false
}

private struct OCRLine: Sendable { let text: String; let rect: CGRect; let confidence: Float }
private struct ImageBox: @unchecked Sendable { let image: CGImage }

enum TextRecognizer {
    /// Recognizes text in an image and groups nearby lines into bubbles.
    /// Coordinates are returned in `size` space (the reader view's points).
    static func blocks(in image: UIImage, size: CGSize, crop: CGRect? = nil) async -> [TextBlock] {
        guard let cg = image.cgImage else { return [] }
        let cgImage: CGImage
        let area = crop ?? CGRect(origin: .zero, size: size)
        if let crop {
            let s = CGFloat(cg.width) / size.width
            guard let c = cg.cropping(to: CGRect(x: crop.minX * s, y: crop.minY * s, width: crop.width * s, height: crop.height * s).integral)
            else { return [] }
            cgImage = c
        } else { cgImage = cg }
        let box = ImageBox(image: cgImage)
        let lines: [OCRLine] = await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ja-JP", "ko-KR", "zh-Hans", "zh-Hant", "en-US"]
            if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = true }
            let handler = VNImageRequestHandler(cgImage: box.image, options: [:])
            do { try handler.perform([request]) } catch { return [] }
            return (request.results ?? []).compactMap { obs -> OCRLine? in
                guard let top = obs.topCandidates(1).first else { return nil }
                let b = obs.boundingBox
                let rect = CGRect(x: area.minX + b.minX * area.width, y: area.minY + (1 - b.maxY) * area.height,
                                  width: b.width * area.width, height: b.height * area.height)
                return OCRLine(text: top.string, rect: rect, confidence: top.confidence)
            }
        }.value
        let useful = lines.filter { line in
            line.confidence > 0.25 && line.text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
        if crop != nil {
            // A user-selected area is one bubble.
            guard !useful.isEmpty else { return [] }
            return [TextBlock(id: UUID().uuidString, rect: area, original: join(useful),
                              translated: nil, confidence: useful.map(\.confidence).min() ?? 0)]
        }
        return group(useful).map { group in
            let rect = group.reduce(CGRect.null) { $0.union($1.rect) }
            return TextBlock(id: UUID().uuidString, rect: rect, original: join(group), translated: nil,
                             confidence: group.map(\.confidence).min() ?? 0)
        }.sorted { a, b in abs(a.rect.minY - b.rect.minY) > 30 ? a.rect.minY < b.rect.minY : a.rect.maxX > b.rect.maxX }
    }

    /// Lines whose slightly enlarged boxes touch belong to the same bubble.
    private static func group(_ lines: [OCRLine]) -> [[OCRLine]] {
        var parent = Array(lines.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        let grown = lines.map { line -> CGRect in
            let pad = max(6, min(line.rect.width, line.rect.height) * 0.6)
            return line.rect.insetBy(dx: -pad, dy: -pad)
        }
        for i in lines.indices { for j in lines.indices where j > i && grown[i].intersects(grown[j]) { parent[find(j)] = find(i) } }
        var groups: [Int: [OCRLine]] = [:]
        for i in lines.indices { groups[find(i), default: []].append(lines[i]) }
        return Array(groups.values)
    }

    /// Joins lines in reading order: vertical CJK columns right-to-left, otherwise top-to-bottom.
    private static func join(_ lines: [OCRLine]) -> String {
        let cjk = lines.contains { $0.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) } }
        let vertical = cjk && lines.filter { $0.rect.height > $0.rect.width * 1.5 }.count * 2 >= lines.count
        let ordered = vertical ? lines.sorted { $0.rect.midX > $1.rect.midX }
                               : lines.sorted { abs($0.rect.minY - $1.rect.minY) > 4 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        let joiner = cjk && !lines.contains { $0.text.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) } } ? "" : " "
        return ordered.map(\.text).joined(separator: joiner)
    }
}

@MainActor
final class TranslateModel: ObservableObject {
    enum Presentation: String, CaseIterable { case overlay = "On the art", list = "Side panel" }
    @Published var active = false
    @Published var blocks: [TextBlock] = []
    @Published var busy = false
    @Published var status: String?
    @Published var hideAll = false
    @Published var selecting = false
    @Published var presentation: Presentation = .overlay
    @Published var editing: TextBlock?
    /// Changes whenever untranslated blocks are ready for the translation session.
    @Published var requestID = 0
    var targetCode = "en"
    private(set) var sourceCode: String?
    private var snapshot: UIImage?
    private(set) var scannedSize: CGSize = .zero
    /// "source|target|text" -> translation, kept between launches.
    private var cache: TranslationMemory { .shared }
    /// The series being read, for "always translate this series".
    var seriesID: String?
    @Published var always = false

    // MARK: Always translate (raw series)
    private static let alwaysKey = "translateSeries"
    static func isAlways(_ seriesID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []).contains(seriesID)
    }
    func setAlways(_ on: Bool) {
        guard let seriesID else { return }
        var list = UserDefaults.standard.stringArray(forKey: Self.alwaysKey) ?? []
        list.removeAll { $0 == seriesID }
        if on { list.append(seriesID) }
        UserDefaults.standard.set(list, forKey: Self.alwaysKey)
        always = on
    }
    /// The detected language isn't the one you read in: this chapter is a raw.
    var looksRaw: Bool { sourceCode != nil && sourceCode != targetCode }

    var supported: Bool { if #available(iOS 18.0, *) { return true } else { return false } }

    func scan(handle: ReaderHandle, size: CGSize) async {
        guard active else { return }
        busy = true; status = nil; blocks = []
        defer { busy = false }
        try? await Task.sleep(for: .milliseconds(450))   // let the page settle after a turn
        guard active, !Task.isCancelled, let image = handle.snapshot() else { return }
        snapshot = image; scannedSize = size
        let found = await TextRecognizer.blocks(in: image, size: size)
        guard active, !Task.isCancelled else { return }
        blocks = found
        status = found.isEmpty ? "No text found. Zoom into a bubble and rescan, or select an area." : nil
        requestTranslations()
    }
    func scanArea(_ rect: CGRect) async {
        guard let snapshot, rect.width > 12, rect.height > 12 else { return }
        busy = true; defer { busy = false }
        let found = await TextRecognizer.blocks(in: snapshot, size: scannedSize, crop: rect)
        if found.isEmpty { status = "No text recognized in that area." } else { status = nil; blocks += found; requestTranslations() }
    }
    func clear() { blocks = []; status = nil; editing = nil }
    func correct(_ id: String, original: String) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[i].original = original; blocks[i].translated = nil
        requestTranslations()
    }
    func toggle(_ id: String) {
        if let i = blocks.firstIndex(where: { $0.id == id }) { blocks[i].showOriginal.toggle() }
    }

    private func key(_ text: String) -> String { "\(sourceCode ?? "auto")|\(targetCode)|\(text)" }
    private func requestTranslations() {
        let pendingText = blocks.filter { $0.translated == nil }.map(\.original).joined(separator: "\n")
        guard !pendingText.isEmpty else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(pendingText)
        sourceCode = recognizer.dominantLanguage.map { $0 == .simplifiedChinese ? "zh-Hans" : $0 == .traditionalChinese ? "zh-Hant" : $0.rawValue }
        for i in blocks.indices where blocks[i].translated == nil {
            if let hit = cache.lookup(key(blocks[i].original)) { blocks[i].translated = hit }
        }
        if sourceCode == targetCode {
            for i in blocks.indices where blocks[i].translated == nil { blocks[i].translated = blocks[i].original }
            return
        }
        guard blocks.contains(where: { $0.translated == nil }) else { return }
        guard supported else { status = "Translation needs iOS 18 or later. Recognized text is shown instead."; return }
        status = "Translating…"
        requestID += 1
    }
    func pending() -> [(String, String)] { blocks.filter { $0.translated == nil }.map { ($0.id, $0.original) } }
    func apply(_ pairs: [(String, String)]) {
        for (id, text) in pairs {
            guard let i = blocks.firstIndex(where: { $0.id == id }) else { continue }
            blocks[i].translated = text
            cache.store(text, for: key(blocks[i].original))
        }
        cache.persist()
        if status == "Translating…" { status = nil }
    }
    func fail(_ message: String) {
        status = "Translation unavailable: \(message). Check Settings › Apps › Translate › Downloaded Languages."
    }
}

/// Translated bubbles, remembered between launches so re-reading a raw chapter is instant (up to 4,000 bubbles).
@MainActor
final class TranslationMemory {
    static let shared = TranslationMemory()
    private var entries: [String: String] = [:]
    private var order: [String] = []
    private var dirty = false
    private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("translations.json")
    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([[String]].self, from: data) {
            for pair in saved where pair.count == 2 { entries[pair[0]] = pair[1]; order.append(pair[0]) }
        }
    }
    func lookup(_ key: String) -> String? { entries[key] }
    func store(_ value: String, for key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = value
        dirty = true
        if order.count > 4000 {
            for old in order.prefix(order.count - 4000) { entries[old] = nil }
            order.removeFirst(order.count - 4000)
        }
    }
    func persist() {
        guard dirty else { return }
        dirty = false
        let pairs = order.compactMap { key in entries[key].map { [key, $0] } }
        let target = file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(pairs) { try? data.write(to: target, options: .atomic) }
        }
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct TranslationSessionBox: @unchecked Sendable { let session: TranslationSession }

@available(iOS 18.0, *)
private func translateBatch(_ box: TranslationSessionBox, items: [(String, String)]) async throws -> [(String, String)] {
    let requests = items.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: $0.0) }
    let responses = try await box.session.translations(from: requests)
    return responses.map { ($0.clientIdentifier ?? "", $0.targetText) }
}

@available(iOS 18.0, *)
private struct TranslationRunner: ViewModifier {
    @ObservedObject var model: TranslateModel
    @State private var configuration: TranslationSession.Configuration?
    @State private var languages = ""
    func body(content: Content) -> some View {
        let model = self.model
        return content
            .translationTask(configuration) { session in
                let items = model.pending()
                guard !items.isEmpty else { return }
                // The session is used only inside this task; the box lets it cross to the
                // nonisolated translation call under Swift 6 strict concurrency.
                let box = TranslationSessionBox(session: session)
                do {
                    let pairs = try await translateBatch(box, items: items)
                    model.apply(pairs)
                } catch {
                    model.fail(error.localizedDescription)
                }
            }
            .onChange(of: model.requestID) { _, _ in
                let wanted = "\(model.sourceCode ?? "auto")>\(model.targetCode)"
                if configuration != nil && languages == wanted { configuration?.invalidate() }
                else {
                    languages = wanted
                    configuration = TranslationSession.Configuration(source: model.sourceCode.map { Locale.Language(identifier: $0) },
                                                                     target: Locale.Language(identifier: model.targetCode))
                }
            }
    }
}
#endif

extension View {
    @ViewBuilder func translationRunner(_ model: TranslateModel) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) { self.modifier(TranslationRunner(model: model)) } else { self }
        #else
        self
        #endif
    }
}

/// Translations drawn over (or beside) the page. Only the cards take touches, so page
/// turns and zoom keep working underneath.
struct TranslationOverlay: View {
    @ObservedObject var model: TranslateModel
    let size: CGSize
    @State private var dragStart: CGPoint?
    @State private var dragRect: CGRect?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if !model.hideAll && model.presentation == .overlay {
                ForEach(model.blocks) { block in card(block) }
            }
            if model.selecting {
                Color.black.opacity(0.001)
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            let start = dragStart ?? v.startLocation
                            dragStart = start
                            dragRect = CGRect(x: min(start.x, v.location.x), y: min(start.y, v.location.y),
                                              width: abs(v.location.x - start.x), height: abs(v.location.y - start.y))
                        }
                        .onEnded { _ in
                            if let rect = dragRect { Task { await model.scanArea(rect) } }
                            dragStart = nil; dragRect = nil; model.selecting = false
                        })
                if let dragRect {
                    Rectangle().strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .frame(width: dragRect.width, height: dragRect.height)
                        .offset(x: dragRect.minX, y: dragRect.minY).allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
    /// English needs width that a vertical Japanese bubble doesn't have: tall, narrow bubbles get a wider card,
    /// centered on the bubble. Text is set in a rounded face, like hand-lettering, and shrinks to fit.
    static func fitted(_ rect: CGRect, text: String) -> CGSize {
        var width = max(rect.width, 90), height = max(rect.height, 36)
        if rect.height > rect.width * 1.6 {
            width = max(width, min(rect.height * 0.8, 200))
            height = max(rect.height * 0.75, 44)
        }
        // Long translations in small bubbles get a little more room.
        let needed = CGFloat(text.count) * 52
        if width * height < needed { let grow = (needed / max(1, width * height)).squareRoot(); width = min(width * grow, 260); height = min(height * grow, 220) }
        return CGSize(width: width, height: height)
    }
    private func card(_ block: TextBlock) -> some View {
        let text = block.showOriginal ? block.original : (block.translated ?? block.original)
        let fit = Self.fitted(block.rect, text: text)
        let width = fit.width, height = fit.height
        return Text(text)
            .font(.system(size: 15, weight: .bold, design: .rounded)).minimumScaleFactor(0.35)
            .multilineTextAlignment(.center).foregroundStyle(.black)
            .padding(4)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97).opacity(block.translated == nil ? 0.75 : 0.95)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(block.showOriginal ? Color.orange : Color.black.opacity(0.25)))
            .offset(x: min(max(0, block.rect.midX - width / 2), max(0, size.width - width)),
                    y: min(max(0, block.rect.midY - height / 2), max(0, size.height - height)))
            .onTapGesture { model.toggle(block.id) }
            .onLongPressGesture { model.editing = block }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(block.translated ?? block.original)
            .accessibilityHint("Tap to show the original. Touch and hold to copy or correct.")
    }
}

/// Side panel: original and translated text together, in reading order.
struct TranslationPanel: View {
    @ObservedObject var model: TranslateModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.blocks) { block in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.original).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(block.translated ?? "…").font(.body).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onLongPressGesture { model.editing = block }
                    Divider()
                }
                if model.blocks.isEmpty { Text(model.status ?? "No text on this page yet.").foregroundStyle(.secondary) }
            }.padding(14)
        }.frame(maxHeight: 220).background(.ultraThinMaterial)
    }
}

/// Copy, or correct the recognized text and translate again.
struct TranslationEditor: View {
    @ObservedObject var model: TranslateModel
    let block: TextBlock
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Recognized text") {
                    TextField("Original", text: $text, axis: .vertical).lineLimit(2...8)
                    Button("Copy original") { UIPasteboard.general.string = text }
                }
                Section("Translation") {
                    Text(block.translated ?? "Not translated yet").textSelection(.enabled)
                    if let t = block.translated { Button("Copy translation") { UIPasteboard.general.string = t } }
                }
                Section {
                    Button("Translate again") { model.correct(block.id, original: text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Bubble").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { text = block.original }
        }.preferredColorScheme(.dark)
    }
}

/// Controls shown while translation mode is on.
struct TranslationBar: View {
    @ObservedObject var model: TranslateModel
    let rescan: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            if model.busy { ProgressView().tint(.white) }
            Text(model.status ?? "\(model.blocks.count) bubble\(model.blocks.count == 1 ? "" : "s")")
                .font(.caption).lineLimit(2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if model.seriesID != nil && (model.looksRaw || model.always) {
                Button { model.setAlways(!model.always) } label: { Image(systemName: model.always ? "pin.fill" : "pin") }
                    .tint(model.always ? .yellow : .white)
                    .accessibilityLabel(model.always ? "Stop translating this series automatically" : "Always translate this series")
            }
            Button { model.hideAll.toggle() } label: { Image(systemName: model.hideAll ? "eye" : "eye.slash") }
                .accessibilityLabel(model.hideAll ? "Show translations" : "Show original page")
            Button { model.selecting.toggle() } label: { Image(systemName: "viewfinder") }
                .tint(model.selecting ? .yellow : .white).accessibilityLabel("Select an area to translate")
            Button { model.presentation = model.presentation == .overlay ? .list : .overlay } label: {
                Image(systemName: model.presentation == .overlay ? "sidebar.trailing" : "text.bubble")
            }.accessibilityLabel(model.presentation == .overlay ? "Show side panel" : "Show on the art")
            Button(action: rescan) { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Scan again")
            Button { model.active = false; model.clear() } label: { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Turn off translation")
        }
        .font(.title3).foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial)
    }
}
