import SwiftUI

@main
struct EclipseReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LibraryModel()
    @Environment(\.scenePhase) private var phase
    @AppStorage("appLock") private var appLock = false
    /// Locked at launch and whenever the app goes to the background (when the lock is on).
    @State private var locked = UserDefaults.standard.bool(forKey: "appLock")
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
                .overlay {
                    if locked && appLock {
                        LockScreen { withAnimation(.easeOut(duration: 0.25)) { locked = false } }
                            .transition(.opacity)
                    }
                }
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
                    if phase == .background && appLock { locked = true; model.showHidden = false }
                    if phase == .active { AutoBackup.runIfDue(model) }
                    if phase == .active || phase == .background { Task { await model.syncPositions() } }
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

/// Answers which orientations the app may turn to, so the reader can hold the screen still.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// The reader's rotation lock: holds whichever way the screen faces now, until released.
@MainActor enum OrientationLock {
    static private(set) var mask: UIInterfaceOrientationMask = .all
    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
    static func hold() {
        guard let scene else { return }
        mask = switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .all
        }
        refresh(scene)
    }
    static func release() {
        guard mask != .all else { return }
        mask = .all
        if let scene { refresh(scene) }
    }
    /// What the lock is holding, for the reader's message.
    static var heldName: String {
        if mask == .all { return "place" }
        return mask == .portrait || mask == .portraitUpsideDown ? "portrait" : "landscape"
    }
    private static func refresh(_ scene: UIWindowScene) {
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}
