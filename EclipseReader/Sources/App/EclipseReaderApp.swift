import SwiftUI

@main
struct EclipseReaderApp: App {
    @StateObject private var model = LibraryModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--reader-regression") {
                    ReaderView(chapter: ReaderTestFixture.chapter)
                } else { RootView() }
                #else
                RootView()
                #endif
            }.environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(.white)
                // Files and the share sheet can hand CBZ/ZIP/PDF files straight to the library.
                .onOpenURL { url in
                    // eclipsereader://open?url=https://… (Safari bookmarklet, Shortcuts, share sheet):
                    // opens that page in the in-app browser, ready to add.
                    if url.scheme == "eclipsereader" {
                        if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                           let target = WebLink.parse(raw) {
                            model.incoming = BrowseTarget(url: target)
                        }
                        return
                    }
                    guard url.isFileURL else { return }
                    Task { do { _ = try await model.importFiles([url], copy: true) } catch { model.error = error.localizedDescription } }
                }
                .onChange(of: phase) { _, phase in
                    if phase != .active { model.save() }
                    if phase == .background && model.state.notifyNew == true { ChapterAlerts.schedule() }
                    if phase == .active { Task { await model.checkForUpdates() } }
                    if phase == .background { Task { try? await model.pipeline.cache.prune() } }
                }
        }
        // iOS wakes the app every few hours (when alerts are on) to look for new chapters.
        .backgroundTask(.appRefresh(ChapterAlerts.refreshID)) {
            await LibraryModel.backgroundRefresh()
        }
    }
}
