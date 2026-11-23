import SwiftUI
import GameController
import CoreSpotlight
import AppIntents
import UniformTypeIdentifiers

// MARK: - Keyboard and game controller page turns

/// Arrow keys, space and game controllers turn pages. Posts which edge was "tapped".
enum PageTurnInput {
    static let notification = Notification.Name("EclipsePageTurn")
    /// 0 = left edge, 1 = right edge, 0.5 = toggle controls; "forward" = next page whatever the direction.
    static func post(edge: CGFloat? = nil, forward: Bool? = nil) {
        var info: [String: Any] = [:]
        if let edge { info["edge"] = Double(edge) }
        if let forward { info["forward"] = forward }
        NotificationCenter.default.post(name: notification, object: nil, userInfo: info)
    }
}

@MainActor
final class ControllerInput {
    static let shared = ControllerInput()
    private var observer: NSObjectProtocol?
    func start() {
        guard observer == nil else { return }
        GCController.controllers().forEach(attach)
        observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { _ in
            Task { @MainActor in GCController.controllers().forEach { ControllerInput.shared.attach($0) } }
        }
    }
    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.dpad.left.pressedChangedHandler = { _, _, pressed in if pressed { PageTurnInput.post(edge: 0) } }
        pad.dpad.right.pressedChangedHandler = { _, _, pressed in if pressed { PageTurnInput.post(edge: 1) } }
        pad.leftShoulder.pressedChangedHandler = { _, _, pressed in if pressed { PageTurnInput.post(forward: false) } }
        pad.rightShoulder.pressedChangedHandler = { _, _, pressed in if pressed { PageTurnInput.post(forward: true) } }
        pad.buttonA.pressedChangedHandler = { _, _, pressed in if pressed { PageTurnInput.post(forward: true) } }
        pad.buttonB.pressedChangedHandler = { _, _, pressed in if pressed { PageTurnInput.post(forward: false) } }
        pad.buttonY.pressedChangedHandler = { _, _, pressed in if pressed { PageTurnInput.post(edge: 0.5) } }
    }
}

/// A key-command host: put it behind a reader and arrow keys / space / page keys turn pages.
final class KeyTurnController: UIViewController {
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override var keyCommands: [UIKeyCommand]? {
        let commands: [(String, Selector)] = [
            (UIKeyCommand.inputLeftArrow, #selector(left)), (UIKeyCommand.inputRightArrow, #selector(right)),
            (" ", #selector(forwardKey)), (UIKeyCommand.inputPageDown, #selector(forwardKey)), (UIKeyCommand.inputDownArrow, #selector(forwardKey)),
            (UIKeyCommand.inputPageUp, #selector(backKey)), (UIKeyCommand.inputUpArrow, #selector(backKey)),
        ]
        return commands.map { input, action in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }
    @objc private func left() { PageTurnInput.post(edge: 0) }
    @objc private func right() { PageTurnInput.post(edge: 1) }
    @objc private func forwardKey() { PageTurnInput.post(forward: true) }
    @objc private func backKey() { PageTurnInput.post(forward: false) }
}

struct KeyTurnCatcher: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyTurnController { KeyTurnController() }
    func updateUIViewController(_ controller: KeyTurnController, context: Context) {}
}

// MARK: - Spotlight

/// Puts library series in iPhone search; tapping one opens it in eclipsereader.
@MainActor
enum SpotlightIndex {
    private static var indexed: [String: String] = [:]
    static func update(_ series: [MangaSeries], hidden: Set<String>) {
        let visible = series.filter { !hidden.contains($0.id) }
        var current: [String: String] = [:]
        for item in visible { current[item.id] = item.title + "|\(item.chapters.count)" }
        guard current != indexed else { return }
        let removed = indexed.keys.filter { current[$0] == nil }
        indexed = current
        let items = visible.map { item -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = item.title
            attributes.contentDescription = item.kind == .book ? "Book\(item.author.map { " · \($0)" } ?? "")" : "\(item.chapters.count) chapters"
            attributes.keywords = ["manga", "eclipsereader", item.kind == .book ? "book" : "comic"]
            return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: "series", attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        if !removed.isEmpty { index.deleteSearchableItems(withIdentifiers: Array(removed), completionHandler: nil) }
        index.indexSearchableItems(items, completionHandler: nil)
    }
}

// MARK: - Siri and Shortcuts

struct ContinueReadingIntent: AppIntent {
    static var title: LocalizedStringResource { "Continue reading" }
    static var description: IntentDescription { IntentDescription("Opens the last chapter or book you were reading.") }
    static var openAppWhenRun: Bool { true }
    @MainActor
    func perform() async throws -> some IntentResult {
        if let model = LibraryModel.current, let chapter = model.lastChapter { model.requestedChapter = chapter }
        return .result()
    }
}

struct CheckNewChaptersIntent: AppIntent {
    static var title: LocalizedStringResource { "Check for new chapters" }
    static var description: IntentDescription { IntentDescription("Looks for new chapters in your eclipsereader library.") }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = LibraryModel.current ?? LibraryModel()
        let before = model.totalNew
        await model.checkForUpdates(force: true)
        let found = model.totalNew - before
        let text = found > 0
            ? "\(found) new chapter\(found == 1 ? "" : "s") in your library."
            : "No new chapters right now. \(model.totalNew) still waiting to be read."
        return .result(dialog: "\(text)")
    }
}

struct EclipseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueReadingIntent(), phrases: ["Continue reading in \(.applicationName)", "Open my manga in \(.applicationName)"],
                    shortTitle: "Continue reading", systemImageName: "book")
        AppShortcut(intent: CheckNewChaptersIntent(), phrases: ["Check for new chapters in \(.applicationName)", "Any new manga in \(.applicationName)"],
                    shortTitle: "New chapters", systemImageName: "sparkles")
    }
}

// MARK: - Handoff

enum Handoff {
    static let readingType = "com.personal.eclipse.reader.reading"
}
