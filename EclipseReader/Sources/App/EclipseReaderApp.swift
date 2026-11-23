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
                    guard url.isFileURL else { return }
                    Task { do { _ = try await model.importFiles([url], copy: true) } catch { model.error = error.localizedDescription } }
                }
                .onChange(of: phase) { _, phase in
                    if phase != .active { model.save() }
                    if phase == .active { Task { await model.checkForUpdates() } }
                    if phase == .background { Task { try? await model.pipeline.cache.prune() } }
                }
        }
    }
}
