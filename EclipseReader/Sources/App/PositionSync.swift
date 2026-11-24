import Foundation

private struct PositionSnapshot: Codable, Sendable {
    var pages: [String: ChapterProgress] = [:]
    var books: [String: BookPosition] = [:]
    var novels: [String: NovelPosition] = [:]
    var last: String?
}

private actor PositionFiles {
    static let shared = PositionFiles()
    func exchange(_ local: PositionSnapshot, in folder: URL, device: String) throws -> [PositionSnapshot] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let dir = folder.appendingPathComponent("EclipseReader Positions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent(device + ".json")
        try JSONEncoder().encode(local).write(to: own, options: .atomic)
        var snapshots: [PositionSnapshot] = []
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file != own {
            if file.pathExtension == "icloud" { try? FileManager.default.startDownloadingUbiquitousItem(at: file); continue }
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(PositionSnapshot.self, from: data) else { continue }
            snapshots.append(snapshot)
        }
        return snapshots
    }
}

extension LibraryModel {
    func syncPositions() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "readerPositionSync"), state.incognito != true, let dir = AutoBackup.resolve() else { return }
        let device = defaults.string(forKey: "readerPositionDevice") ?? UUID().uuidString
        defaults.set(device, forKey: "readerPositionDevice")
        var chapterKeys: [String: String] = [:], seriesKeys: [String: String] = [:]
        for series in [berserk] + allSeries where !isHidden(series) {
            seriesKeys[OfflineStore.key(series.id)] = series.id
            for chapter in series.chapters { chapterKeys[OfflineStore.key(chapter.id)] = chapter.id }
        }
        var local = PositionSnapshot()
        for (key, id) in chapterKeys { local.pages[key] = state.progress[id] }
        for (key, id) in seriesKeys {
            local.books[key] = state.bookPositions?[id]
            if var pos = state.novelPositions?[id] {
                pos.chapterID = OfflineStore.key(pos.chapterID)
                local.novels[key] = pos
            }
        }
        local.last = state.lastChapterID.map(OfflineStore.key)
        do {
            let remote = try await PositionFiles.shared.exchange(local, in: dir, device: device)
            guard defaults.bool(forKey: "readerPositionSync"), state.incognito != true, AutoBackup.resolve() == dir else { return }
            var lastDate = state.lastChapterID.flatMap { state.progress[$0]?.updated } ?? .distantPast
            for other in remote {
                for (key, pos) in other.pages {
                    guard let id = chapterKeys[key], pos.updated > (state.progress[id]?.updated ?? .distantPast) else { continue }
                    state.progress[id] = pos
                    if key == other.last, pos.updated > lastDate { state.lastChapterID = id; lastDate = pos.updated }
                }
                var books = state.bookPositions ?? [:], novels = state.novelPositions ?? [:]
                for (key, pos) in other.books {
                    if let id = seriesKeys[key], pos.updated > (books[id]?.updated ?? .distantPast) { books[id] = pos }
                }
                for (key, var pos) in other.novels {
                    if let id = seriesKeys[key], let chapter = chapterKeys[pos.chapterID], pos.updated > (novels[id]?.updated ?? .distantPast) {
                        pos.chapterID = chapter; novels[id] = pos
                    }
                }
                state.bookPositions = books; state.novelPositions = novels
            }
            if !remote.isEmpty { save() }
        } catch { persistenceError = "Couldn’t sync reading positions. " + error.localizedDescription }
    }
}