import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var chapter: Chapter
    @State private var pages: [MangaPage] = []
    @State private var page = 0
    @State private var loading = true
    @State private var failure: String?
    @State private var controls = true
    @State private var settings = false
    @State private var website = false
    @State private var end = false
    @State private var retry = 0
    @State private var wide = Set<Int>()
    @State private var dimming = 0.0
    @AppStorage("readerWarmth") private var warmth = 0.0
    @State private var webtoon = false
    @StateObject private var translator = TranslateModel()
    @State private var handle = ReaderHandle()
    @State private var scanNonce = 0
    @State private var tallPages = 0
    /// Global (manga) settings adjusted for this series' style: manhwa scrolls vertically,
    /// comics read left to right. Tall strips switch to vertical even before a style is known.
    private var effective: ReaderPreferences {
        let seriesID = library.seriesID(for: chapter)
        var style = library.style(for: seriesID)
        if webtoon && (library.preferences.autoWebtoon ?? true) && library.styleOverride(seriesID) == .automatic { style = .manhwa }
        return library.preferences.applying(style)
    }
    /// Only real webtoon strips (much taller than a printed page, even after margin trimming) count.
    /// The built-in Berserk source is manga and is never switched automatically.
    private func markWebtoon() {
        guard !webtoon, library.seriesID(for: chapter) != LibraryModel.berserkID else { return }
        webtoon = true
        let seriesID = library.seriesID(for: chapter)
        if library.styleOverride(seriesID) == .automatic && (library.preferences.autoWebtoon ?? true) {
            library.rememberDetected(.manhwa, for: seriesID)
        }
    }
    init(chapter: Chapter) { _chapter = State(initialValue: chapter) }
    private var prefetchKey: String { "\(chapter.id)-\(page)-\(phase == .active)-\(pages.count)" }
    var body: some View {
        GeometryReader { geometry in
            let groups = ReadingOrder.groups(count: pages.count, landscape: ReadingOrder.canPair(width: geometry.size.width, height: geometry.size.height),
                spreads: effective.landscapeSpreads, wide: effective.detectWidePages ? wide : [])
            let showBars = controls || failure != nil || loading
            VStack(spacing: 0) {
                if showBars { readerHeader }
                ZStack {
                    Color.black
                    if loading { ProgressView("Opening chapter…").tint(.white) }
                    else if let failure {
                        VStack(spacing: 20) {
                            SourceNotice(message: failure) { retry += 1 }
                            if chapter.url.scheme == "https" {
                                Button("Open Website Mode") { website = true }.buttonStyle(.borderedProminent).tint(.gray)
                            }
                        }.padding(24)
                    } else {
                        ReaderSurface(pages: pages, groups: groups, chapter: chapter, pipeline: library.pipeline,
                            preferences: effective, handle: handle, page: $page,
                            tap: { withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() } },
                            dimensions: { index, ratio in
                                if ratio > 1.15 && effective.detectWidePages { wide.insert(index) }
                                if ratio < 0.36 { tallPages += 1; if tallPages >= 3 || pages.count == 1 { markWebtoon() } }
                            })

                    }
                    Color(red: 1.0, green: 0.62, blue: 0.32).opacity(warmth).blendMode(.multiply).allowsHitTesting(false)
                    Color.black.opacity(dimming).allowsHitTesting(false)
                    if translator.active && !pages.isEmpty {
                        GeometryReader { area in
                            TranslationOverlay(model: translator, size: area.size)
                                .task(id: "\(chapter.id)|\(page)|\(Int(area.size.width))x\(Int(area.size.height))|\(scanNonce)") {
                                    await translator.scan(handle: handle, size: area.size)
                                }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if translator.active {
                    if translator.presentation == .list { TranslationPanel(model: translator) }
                    TranslationBar(model: translator) { scanNonce += 1 }
                }
                if showBars && !pages.isEmpty { navigationBar(groups: groups) }
            }.foregroundStyle(.white)
                .statusBarHidden(!controls)
                .persistentSystemOverlays(controls ? .automatic : .hidden)
                .task(id: "\(chapter.id)-\(retry)") { await load() }
                .task(id: prefetchKey) {
                    guard phase == .active, !pages.isEmpty else { return }
                    let last = groups.first(where: { $0.indices.contains(page) })?.indices.last ?? page
                    let start = min(last + 1, pages.count)
                    await library.pipeline.prefetch(Array(pages.dropFirst(start).prefix(2)), chapter: chapter)
                }
                .onChange(of: page) { _, _ in remember() }
                .onChange(of: phase) { _, phase in if phase != .active { remember() } }
                .onDisappear { remember() }
                .sheet(isPresented: $settings) {
                    NavigationStack {
                        Form {
                            Section {
                                Picker("This series reads as", selection: Binding(
                                    get: { library.styleOverride(library.seriesID(for: chapter)) },
                                    set: { library.setStyle($0, for: library.seriesID(for: chapter)) })) {
                                    ForEach(ReadingStyle.allCases, id: \.self) { style in
                                        Label(style.title, systemImage: style.symbol).tag(style)
                                    }
                                }
                            } footer: {
                                Text("Now: \(library.style(for: library.seriesID(for: chapter)).title) · \(library.style(for: library.seriesID(for: chapter)).detail). The settings below are your manga defaults.")
                            }
                            ReaderPreferencesForm(preferences: Binding(get: { library.preferences }, set: { library.preferences = $0 }))
                            Section("Screen dimming") {
                                Slider(value: $dimming, in: 0...0.7) { Text("Dim artwork") }
                                Slider(value: $warmth, in: 0...0.6) { Text("Warm filter") }
                                Text("Warm filter: \(Int(warmth * 100))% · stays on between sessions").font(.caption).foregroundStyle(.secondary)
                                Text("Applies inside this reader only.").foregroundStyle(.secondary)
                            }
                        }.navigationTitle("Reader settings").navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Done") { settings = false } }
                    }.preferredColorScheme(.dark)
                }
                .sheet(isPresented: $website) { WebsiteView(url: chapter.url) }
                .sheet(item: $translator.editing) { block in TranslationEditor(model: translator, block: block) }
                .translationRunner(translator)
                .onChange(of: chapter.id) { _, _ in translator.clear() }
                .confirmationDialog("End of chapter", isPresented: $end, titleVisibility: .visible) {
                    if let next = library.next(after: chapter) {
                        Button("Mark read & open \(next.title)") {
                            library.record(chapter, page: max(0, pages.count - 1), count: pages.count, completed: true)
                            pages = []; loading = true; chapter = next
                        }
                    }
                    Button("Mark chapter read") {
                        library.record(chapter, page: max(0, pages.count - 1), count: pages.count, completed: true)
                    }
                    Button("Keep reading", role: .cancel) {}
                }
        }.background(.black)
    }
    private var readerHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Close reader")
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title).font(.headline).lineLimit(1)
                Text(effective.mode == .vertical ? "Vertical" : effective.direction.title)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                translator.targetCode = library.preferences.translateTarget ?? "en"
                if translator.active { translator.active = false; translator.clear() } else { translator.active = true; scanNonce += 1 }
            } label: {
                Image(systemName: translator.active ? "character.bubble.fill" : "character.bubble").frame(width: 44, height: 44)
            }.accessibilityLabel(translator.active ? "Turn off translation" : "Translate this page")
                .accessibilityIdentifier("translatePage")
            Menu {
                Button("Reading settings", systemImage: "slider.horizontal.3") { settings = true }
                if chapter.url.scheme == "https" { Button("Website Mode", systemImage: "globe") { website = true } }
                Button("Reload chapter", systemImage: "arrow.clockwise") { retry += 1 }
                if library.canDownload(chapter) && !library.isDownloaded(chapter) && library.downloads[chapter.id] == nil {
                    Button("Download chapter", systemImage: "arrow.down.circle") { library.download([chapter]) }
                }
                if pages.indices.contains(page) {
                    Button("Use this page as cover", systemImage: "photo") {
                        let current = pages[page]
                        let seriesID = library.seriesID(for: chapter)
                        Task { try? await library.chooseCoverPage(current, seriesID: seriesID) }
                    }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("Reader options")
        }.padding(.horizontal, 8).padding(.vertical, 4).background(.ultraThinMaterial)
    }
    private func navigationBar(groups: [PageGroup]) -> some View {
        VStack(spacing: 14) {
            HStack {
                Button("Previous") { move(-1, groups: groups) }.disabled(page == 0)
                Spacer()
                Text("\(page + 1) / \(pages.count)").monospacedDigit().font(.subheadline)
                    .accessibilityLabel("Page \(page + 1) of \(pages.count)").accessibilityIdentifier("logicalPage")
                Spacer()
                Button("Next") { move(1, groups: groups) }
            }.frame(minHeight: 36)
            Slider(value: Binding(get: { Double(page) }, set: { page = Int($0.rounded()) }),
                in: 0...Double(max(1, pages.count - 1)), step: 1)
                .disabled(pages.count == 1).accessibilityLabel("Page position")
        }.padding(.horizontal, 24).padding(.vertical, 12).background(.ultraThinMaterial)
    }
    private func load() async {
        loading = true; failure = nil; pages = []; wide = []
        let requested = chapter
        do {
            let result = try await library.pages(for: requested)
            try Task.checkCancellation()
            guard requested.id == chapter.id else { return }
            page = min(library.state.progress[chapter.id]?.page ?? 0, max(0, result.count - 1))
            pages = result
            library.downloadAhead(after: requested)
            let tall = result.filter { p in (p.width ?? 1) > 0 && (p.height ?? 0) / (p.width ?? 1) > 2 }.count
            if tall >= 3 { markWebtoon() }
            wide = Set(result.indices.filter { i in
                guard let w = result[i].width, let h = result[i].height, h > 0 else { return false }
                return w / h > 1.15
            })
            loading = false; remember()
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { if !Task.isCancelled && requested.id == chapter.id { failure = error.localizedDescription; loading = false } }
    }
    private func remember() {
        guard !loading, !pages.isEmpty else { return }
        library.record(chapter, page: page, count: pages.count)
    }
    private func move(_ delta: Int, groups: [PageGroup]) {
        guard !groups.isEmpty else { return }
        if effective.mode == .vertical {
            if page + delta >= pages.count { end = true }
            else { page = max(0, page + delta) }
        } else if let index = groups.firstIndex(where: { $0.indices.contains(page) }) {
            if index + delta >= groups.count { end = true }
            else if index + delta >= 0 { page = groups[index + delta].id }
        }
    }
}

struct ReaderSurface: UIViewControllerRepresentable {
    let pages: [MangaPage]
    let groups: [PageGroup]
    let chapter: Chapter
    let pipeline: ImagePipeline
    let preferences: ReaderPreferences
    let handle: ReaderHandle
    @Binding var page: Int
    let tap: () -> Void
    let dimensions: (Int, Double) -> Void
    func makeUIViewController(context: Context) -> ReaderContainerController {
        let controller = ReaderContainerController()
        handle.controller = controller
        return controller
    }
    func updateUIViewController(_ vc: ReaderContainerController, context: Context) {
        vc.configure(pages: pages, groups: groups, chapter: chapter, pipeline: pipeline,
                     preferences: preferences, page: page,
                     changed: { page = $0 }, tap: tap, dimensions: dimensions)
    }
}
