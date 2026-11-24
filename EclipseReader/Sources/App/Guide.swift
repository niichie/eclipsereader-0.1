import SwiftUI

/// A plain-language tour of what everything does: from Settings, the end of the setup, and the reader's settings.
struct GuideView: View {
    @AppStorage(Features.novelsKey) private var novelsOn = false
    @AppStorage(Features.booksKey) private var booksOn = false
    var body: some View {
        List {
            Section {
                Text("Everything in eclipsereader, in a minute. Each part is also explained where you change it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            Section("Reading manga and comics") {
                item("hand.tap", "Turning pages", "Tap the left or right edge, or swipe. Manga reads right to left, so its left edge goes forward. Tap the middle to show or hide the controls. Keyboards and game controllers turn pages too.")
                item("book.pages", "LTR · RTL · Scroll", "The first button in the reader's bottom bar sets how this series reads: right-to-left page turns (manga), left-to-right (comics), or one continuous vertical strip (manhwa, manhua, webtoons). It's detected for you; change it when it guesses wrong.")
                item("square.grid.3x1.below.line.grid.1x2", "Panels (guided view)", "Instead of turning the whole page, an edge tap zooms to the next panel and walks you through the page one panel at a time, then turns the page. Handy on small screens. Pages without clear panel borders turn normally.")
                item("plus.magnifyingglass", "Zoom", "Double-tap to zoom in (how far is in Settings › Reader), pinch for anything in between.")
                item("character.bubble", "Translate", "The speech-bubble button reads the text on the page and translates it on your device, drawn over the art or in a side panel. Long-press it in a raw series to always translate that series.")
                item("bookmark", "Bookmarks", "The bookmark button marks the page you're on. Find them all in the library's ⋯ menu › Bookmarks.")
                item("sun.min", "Dim artwork", "Darkens the pages for this reading session, below the phone's own brightness.")
                item("flame", "Warm filter", "Tints pages amber for reading at night. It stays on until you turn it down, in the reader's settings or Settings › Reader.")
                item("wand.and.stars", "Enhance scanned pages", "Reduces scan noise and enlarges small pages on this device. Uses more battery; leave it off for clean digital pages.")
                item("crop", "Blank borders", "Plain white or black borders around scanned pages are trimmed automatically so the art fills the screen. Switch it off in Settings › Reader if a page ever looks cut.")
                item("rectangle.split.2x1", "Spreads", "Turn the phone sideways for two pages side by side. In portrait, a double-page spread can be split into two pages.")
                item("arrow.down.to.line", "Auto-scroll", "In vertical strips, the bottom bar can glide the strip at the speed you pick until you touch it.")
            }
            Section("Your library") {
                item("plus.circle", "Adding series", "Search every site at once in Browse, open a series and tap Add, or paste a link with the + button. Files (CBZ, CBR, ZIP, PDF, folders of images) import from the + button too.")
                item("star", "Favourites and categories", "Long-press a cover for options. Favourite a series from its ⋯ menu; make your own shelves in Settings › Library › Categories. Both show as tabs.")
                item("sparkles", "Updates", "New chapters are checked every few hours when you open the app (pull down to check now). Turn on notifications in the Updates tab.")
                item("arrow.down.circle", "Downloads", "Download chapters from a series' ⋯ menu or by swiping a chapter. Settings › Downloads has Wi-Fi only, download ahead while reading, and delete after reading.")
                item("eye.slash", "Hidden series", "Long-press a cover › Hide. Hidden series show again only after Face ID.")
            }
            Section("Sources and sign-ins") {
                item("safari", "Sources", "Browse groups sites by what they offer. Browse › Manage sources lets you rename, hide, remove, reorder and favourite them, add your own, or add a whole list (pasted, from a file, or a link you subscribe to).")
                item("person.crop.circle.badge.checkmark", "Signing in", "Sign in on a site inside the in-app browser, like you would in Safari; it stays signed in. In a source's settings, “Read with my browser sign-in” makes the reader load that site through the same session, so what your account can see opens in the reader too. Your password and session never leave the browser.")
                item("square.stack.3d.up.badge.automatic", "Fill missing chapters", "On a series' ⋯ menu: when a site is missing chapters, the same series on another site fills the gaps. Filled chapters give way once the main site has them.")
                item("arrow.triangle.swap", "Migrate", "Moves a series to another site and keeps your place, if its site closes or moves.")
                item("sparkles.rectangle.stack", "Similar series", "On a series' ⋯ menu: what AniList readers recommend for it.")
                item("arrow.triangle.2.circlepath", "AniList tracking", "Link a series to AniList (Settings › Tracking) and finished chapters update your list.")
            }
            if novelsOn || booksOn {
                Section("Novels and books") {
                    item("text.book.closed", "Set like a printed book", "Typeface, size, spacing, margins and paper colour are under the Aa button. Turn the phone sideways for two pages side by side.")
                    if novelsOn {
                        item("arrow.right.to.line", "Chapter to chapter", "A novel carries straight on into the next chapter when you turn past the last page. The list button jumps anywhere.")
                        item("character.bubble", "Translating raws", "Japanese, Chinese and Korean novels translate paragraph by paragraph on the device with the speech-bubble button. Syosetu starts each chapter in Japanese.")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Eclipse.surface)
        .navigationTitle("Guide").navigationBarTitleDisplayMode(.inline)
    }
    private func item(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Eclipse.highlight).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
