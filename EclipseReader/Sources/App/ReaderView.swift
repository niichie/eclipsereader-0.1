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
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    @State private var webtoon = false
    @StateObject private var translator = TranslateModel()
    @State private var handle = ReaderHandle()
    @State private var scanNonce = 0
    @State private var tallPages = 0
    @State private var pickingCover = false
    @State private var toast: String?
    /// Global (manga) settings adjusted for this series' style: manhwa scrolls vertically,
    /// comics read left to right. Tall strips switch to vertical even before a style is known.
    private var effective: ReaderPreferences {
        let seriesID = library.seriesID(for: chapter)
        var style = library.style(for: seriesID)
        if webtoon && (library.preferences.autoWebtoon ?? true) && library.styleOverride(seriesID) == .automatic && !style.scrolls { style = .webtoon }
        return library.preferences.applying(style)
    }
    /// Only real webtoon strips (much taller than a printed page, even after margin trimming) count.
    /// The built-in Berserk source is manga and is never switched automatically.
    private func markWebtoon() {
        guard !webtoon, library.seriesID(for: chapter) != LibraryModel.berserkID else { return }
        webtoon = true
        let seriesID = library.seriesID(for: chapter)
        if library.styleOverride(seriesID) == .automatic && (library.preferences.autoWebtoon ?? true) {
            if !library.style(for: seriesID).scrolls { library.rememberDetected(.webtoon, for: seriesID) }
        }
    }
    init(chapter: Chapter) { _chapter = State(initialValue: chapter) }
    private var prefetchKey: String { "\(chapter.id)-\(page)-\(phase == .active)-\(pages.count)" }
    var body: some View {
        GeometryReader { geometry in
            let groups = ReadingOrder.groups(count: pages.count, landscape: ReadingOrder.canPair(width: geometry.size.width, height: geometry.size.height),
                spreads: effective.landscapeSpreads, wide: effective.detectWidePages ? wide : [])
            let showBars = controls || failure != nil || loading
            ZStack {
                ZStack {
                    Color.black
                    if loading {
                        VStack(spacing: 14) {
                            EclipseMark(size: 44).symbolEffectPulse()
                            Text("Opening \(chapter.title)…").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.horizontal, 32)
                    } else if let failure {
                        VStack(spacing: 16) {
                            SourceNotice(message: failure) { retry += 1 }
                            if chapter.url.scheme == "https" {
                                Button("Open in browser", systemImage: "safari") { website = true }
                                    .buttonStyle(.borderedProminent).tint(Eclipse.accent)
                            }
                        }.padding(24).frame(maxWidth: 520)
                    } else {
                        ReaderSurface(pages: pages, groups: groups, chapter: chapter, pipeline: library.pipeline,
                            preferences: effective, handle: handle, page: $page,
                            tap: { x in tapped(at: x, groups: groups) },
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
                // Artwork uses the whole screen, like Mihon: pages are centred in the full display
                // (including under the Duo's status column) instead of being pushed to one side.
                .ignoresSafeArea()

                // Controls float over the page so it never resizes when they appear.
                VStack(spacing: 0) {
                    if showBars {
                        readerHeader.transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if translator.active {
                        if translator.presentation == .list { TranslationPanel(model: translator) }
                        TranslationBar(model: translator) { scanNonce += 1 }
                    }
                    if showBars && !pages.isEmpty {
                        navigationBar(groups: groups).transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !pages.isEmpty, page >= pages.count - 1, let next = library.next(after: chapter) {
                        // Reached the end: offer the next chapter right where your thumb is.
                        Button {
                            library.record(chapter, page: max(0, pages.count - 1), count: pages.count, completed: true)
                            open(next)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("NEXT").font(.caption2.weight(.heavy)).tracking(1.2).foregroundStyle(.black.opacity(0.6))
                                    Text(ChapterText.split(next.title).name).font(.subheadline.weight(.bold)).lineLimit(1)
                                }
                                Image(systemName: "arrow.right").font(.subheadline.weight(.heavy))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18).frame(height: 52)
                            .background(Eclipse.highlight, in: Capsule())
                            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                        }
                        .buttonStyle(PressableStyle())
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityLabel("Next chapter, \(next.title)")
                    }
                }
            }.foregroundStyle(.white)
                .statusBarHidden(!showBars)
                .persistentSystemOverlays(showBars ? .automatic : .hidden)
                .animation(.snappy(duration: 0.22), value: showBars)
                .task(id: "\(chapter.id)-\(retry)") { await load() }
                .task(id: prefetchKey) {
                    guard phase == .active, !pages.isEmpty else { return }
                    let last = groups.first(where: { $0.indices.contains(page) })?.indices.last ?? page
                    let start = min(last + 1, pages.count)
                    await library.pipeline.prefetch(Array(pages.dropFirst(start).prefix(2)), chapter: chapter)
                }
                .onChange(of: page) { _, _ in remember() }
                .onChange(of: phase) { _, phase in if phase != .active { remember() } }
                .onDisappear { remember(); UIApplication.shared.isIdleTimerDisabled = false }
                .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
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
                .onReceive(NotificationCenter.default.publisher(for: ZoomPageView.useAsCover)) { note in
                    guard let index = note.userInfo?["index"] as? Int, pages.indices.contains(index) else { return }
                    let current = pages[index]
                    let seriesID = library.seriesID(for: chapter)
                    let source = chapter
                    Task {
                        do {
                            try await library.chooseCoverPage(current, seriesID: seriesID, chapter: source)
                            flash("Cover updated")
                        } catch { flash("Couldn’t use this page") }
                    }
                }
                .sheet(isPresented: $pickingCover) {
                    if let series = library.series(id: library.seriesID(for: chapter)) {
                        CoverPicker(series: series).environmentObject(library)
                    }
                }
                .overlay(alignment: .top) {
                    if let toast {
                        Label(toast, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 70)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
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
    private var seriesTitle: String? {
        library.series(id: library.seriesID(for: chapter))?.title
    }
    private var readerHeader: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44)
            }.accessibilityLabel("Close reader")
            VStack(alignment: .leading, spacing: 1) {
                if let seriesTitle {
                    Text(seriesTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(chapter.title).font(.subheadline.weight(.bold)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                translator.targetCode = library.preferences.translateTarget ?? "en"
                if translator.active { translator.active = false; translator.clear() } else { translator.active = true; scanNonce += 1 }
            } label: {
                Image(systemName: translator.active ? "character.bubble.fill" : "character.bubble")
                    .foregroundStyle(translator.active ? Eclipse.highlight : .white)
                    .frame(width: 44, height: 44)
            }.accessibilityLabel(translator.active ? "Turn off translation" : "Translate this page")
                .accessibilityIdentifier("translatePage")
            Menu {
                if chapter.url.scheme == "https" { Button("Open in browser", systemImage: "safari") { website = true } }
                Button("Reload chapter", systemImage: "arrow.clockwise") { retry += 1 }
                if library.canDownload(chapter) && !library.isDownloaded(chapter) && library.downloads[chapter.id] == nil {
                    Button("Download chapter", systemImage: "arrow.down.circle") { library.download([chapter]) }
                }
                Section("Cover") {
                    if pages.indices.contains(page) {
                        Button("Use this page as cover", systemImage: "photo") {
                            let current = pages[page]
                            let seriesID = library.seriesID(for: chapter)
                            let source = chapter
                            Task {
                                do {
                                    try await library.chooseCoverPage(current, seriesID: seriesID, chapter: source)
                                    flash("Cover updated")
                                } catch { flash("Couldn’t use this page: \(error.localizedDescription)") }
                            }
                        }
                    }
                    Button("Change cover…", systemImage: "photo.on.rectangle.angled") { pickingCover = true }
                }
                if chapter.url.scheme == "https" {
                    ShareLink(item: chapter.url) { Label("Share link", systemImage: "square.and.arrow.up") }
                }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel("Reader options")
        }
        .font(.title3)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Eclipse.hairline).frame(height: 0.5) }
    }
    /// Page slider between previous/next chapter buttons; flipped for right-to-left manga so
    /// the slider moves the same way the pages do. Below it, quick settings.
    private func navigationBar(groups: [PageGroup]) -> some View {
        let rtl = effective.mode == .paged && effective.direction == .rightToLeft
        let previous = library.previous(before: chapter)
        let next = library.next(after: chapter)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                chapterButton("backward.end.fill", "Previous chapter", enabled: previous != nil) { if let previous { open(previous) } }
                HStack(spacing: 10) {
                    Text("\(page + 1)").monospacedDigit().font(.footnote.weight(.semibold)).frame(minWidth: 22)
                        .accessibilityLabel("Page \(page + 1) of \(pages.count)").accessibilityIdentifier("logicalPage")
                    Slider(value: Binding(get: { Double(page) }, set: { page = Int($0.rounded()) }),
                           in: 0...Double(max(1, pages.count - 1)), step: 1)
                        .tint(Eclipse.accent)
                        .disabled(pages.count == 1).accessibilityLabel("Page position")
                    Text("\(pages.count)").monospacedDigit().font(.footnote).foregroundStyle(.secondary).frame(minWidth: 22)
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(.thinMaterial, in: Capsule())
                chapterButton("forward.end.fill", "Next chapter", enabled: next != nil) { if let next { open(next) } }
            }
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            HStack(spacing: 0) {
                Menu {
                    Picker("This series reads as", selection: Binding(
                        get: { library.styleOverride(library.seriesID(for: chapter)) },
                        set: { library.setStyle($0, for: library.seriesID(for: chapter)) })) {
                        ForEach(ReadingStyle.allCases, id: \.self) { style in
                            Label(style.title, systemImage: style.symbol).tag(style)
                        }
                    }
                } label: { quickLabel(effective.mode == .vertical ? "arrow.up.and.down.text.horizontal" : "book.pages", effective.mode == .vertical ? "Scroll" : (rtl ? "RTL" : "LTR")) }
                    .accessibilityLabel("Reading mode")
                if effective.mode == .paged {
                    Button { toggleTrim() } label: { quickLabel("crop", "Crop", on: effective.trimMargins ?? true) }
                        .accessibilityLabel("Trim page margins")
                } else {
                    Button { library.preferences.verticalGap = !(library.preferences.verticalGap ?? false) } label: {
                        quickLabel("rectangle.split.1x2", "Gap", on: library.preferences.verticalGap ?? false)
                    }.accessibilityLabel("Gap between pages")
                }
                Button { warmth = warmth > 0 ? 0 : 0.3 } label: { quickLabel("moon.haze", "Warm", on: warmth > 0) }
                    .accessibilityLabel("Warm night filter")
                Button { settings = true } label: { quickLabel("slider.horizontal.3", "Settings") }
                    .accessibilityLabel("Reading settings")
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Eclipse.hairline).frame(height: 0.5) }
    }
    private func chapterButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44).background(.thinMaterial, in: Circle())
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
    private func quickLabel(_ symbol: String, _ title: String, on: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            Text(title).font(.caption2.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(on ? Eclipse.highlight : .white)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    private func flash(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.snappy) { if toast == text { toast = nil } }
        }
    }
    private func toggleTrim() {
        library.preferences.trimMargins = !(library.preferences.trimMargins ?? true)
    }
    private func open(_ target: Chapter) {
        remember()
        pages = []; loading = true; chapter = target
    }
    /// Tap the left or right edge to turn the page (direction-aware), the middle to show or hide controls.
    private func tapped(at x: CGFloat, groups: [PageGroup]) {
        let zones = (library.preferences.tapZones ?? true) && effective.mode == .paged
        if zones && (x < 0.3 || x > 0.7) {
            let leftward = x < 0.3
            let forward = effective.direction == .rightToLeft ? leftward : !leftward
            if controls { controls = false }
            move(forward ? 1 : -1, groups: groups)
        } else {
            controls.toggle()
        }
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
            #if DEBUG
            let testing = ProcessInfo.processInfo.arguments.contains("--reader-regression")
            #else
            let testing = false
            #endif
            if !testing {
                // Show the controls briefly, then get out of the way of the artwork.
                try? await Task.sleep(for: .seconds(2.2))
                if requested.id == chapter.id && !Task.isCancelled { controls = false }
            }
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
    let tap: (CGFloat) -> Void
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
