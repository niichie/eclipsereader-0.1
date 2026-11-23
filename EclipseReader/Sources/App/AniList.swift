import Foundation

/// AniList tracking (filled in with sign-in and sync in a later step).
enum AniList {
    @MainActor static func chapterFinished(_ chapter: Chapter, model: LibraryModel) async {}
}
