import SwiftUI

/// One short line from manga, manhwa and anime-adjacent classics, shown on the library at each launch.
struct MangaQuote: Hashable, Sendable {
    let text: String
    let who: String
    let work: String
}

/// Lines only from the best-rated works: manga that score 8+ on MyAnimeList (most 9+), and books
/// rated 4+ on Goodreads. Short lines, attributed.
enum Quotes {
    static let manga: [MangaQuote] = [
        MangaQuote(text: "In this world, is the destiny of mankind controlled by some transcendental entity or law?", who: "Narration", work: "Berserk"),
        MangaQuote(text: "You have no enemies. No one in this world has any enemies.", who: "Thors", work: "Vinland Saga"),
        MangaQuote(text: "A true warrior needs no sword.", who: "Thors", work: "Vinland Saga"),
        MangaQuote(text: "If you give up, that's when the game is over.", who: "Coach Anzai", work: "Slam Dunk"),
        MangaQuote(text: "A lesson without pain is meaningless.", who: "Edward Elric", work: "Fullmetal Alchemist"),
        MangaQuote(text: "If you don't take risks, you can't create a future.", who: "Monkey D. Luffy", work: "One Piece"),
        MangaQuote(text: "The only thing humans are equal in is death.", who: "Johan Liebert", work: "Monster"),
        MangaQuote(text: "You should enjoy the little detours to the fullest.", who: "Ging Freecss", work: "Hunter × Hunter"),
        MangaQuote(text: "If you win, you live. If you lose, you die. If you don't fight, you can't win!", who: "Eren Yeager", work: "Attack on Titan"),
        MangaQuote(text: "I'll leave tomorrow's problems to tomorrow's me.", who: "Saitama", work: "One-Punch Man"),
        MangaQuote(text: "Arise.", who: "Sung Jinwoo", work: "Solo Leveling"),
        MangaQuote(text: "Throughout Heaven and Earth, I alone am the honored one.", who: "Satoru Gojo", work: "Jujutsu Kaisen"),
        MangaQuote(text: "Stand proud. You are strong.", who: "Ryomen Sukuna", work: "Jujutsu Kaisen"),
        MangaQuote(text: "Hard work is worthless for those that don't believe in themselves.", who: "Naruto Uzumaki", work: "Naruto"),
    ]
    static let books: [MangaQuote] = [
        MangaQuote(text: "Live for more.", who: "Eo", work: "Red Rising"),
        MangaQuote(text: "Fear is the mind-killer.", who: "Frank Herbert", work: "Dune"),
        MangaQuote(text: "Not all those who wander are lost.", who: "J.R.R. Tolkien", work: "The Fellowship of the Ring"),
        MangaQuote(text: "Life before death. Strength before weakness. Journey before destination.", who: "The First Ideal", work: "The Way of Kings"),
        MangaQuote(text: "There's always another secret.", who: "Kelsier", work: "Mistborn"),
        MangaQuote(text: "Fist my bump.", who: "Rocky", work: "Project Hail Mary"),
        MangaQuote(text: "Winter is coming.", who: "Eddard Stark", work: "A Game of Thrones"),
        MangaQuote(text: "It is our choices that show what we truly are, far more than our abilities.", who: "Albus Dumbledore", work: "Harry Potter and the Chamber of Secrets"),
        MangaQuote(text: "Don't Panic.", who: "Douglas Adams", work: "The Hitchhiker's Guide to the Galaxy"),
        MangaQuote(text: "Who controls the past controls the future.", who: "George Orwell", work: "1984"),
        MangaQuote(text: "So it goes.", who: "Kurt Vonnegut", work: "Slaughterhouse-Five"),
        MangaQuote(text: "I am no bird; and no net ensnares me.", who: "Jane Eyre", work: "Jane Eyre"),
        MangaQuote(text: "We accept the love we think we deserve.", who: "Charlie", work: "The Perks of Being a Wallflower"),
        MangaQuote(text: "Tomorrow is always fresh, with no mistakes in it yet.", who: "Anne Shirley", work: "Anne of Green Gables"),
        MangaQuote(text: "The mystery of human existence lies not in just staying alive, but in finding something to live for.", who: "Fyodor Dostoevsky", work: "The Brothers Karamazov"),
    ]
    static var all: [MangaQuote] { manga }
    /// Picked once per launch.
    static let launch = manga.randomElement() ?? manga[0]
    static let launchBook = books.randomElement() ?? books[0]
}

/// The launch quote: big serif line, eclipse-coloured rule. "Read" takes you to the series it's
/// from (your library, or a search of every site), the shuffle button picks another, × closes it.
struct QuoteCard: View {
    @State private var quote: MangaQuote
    let pool: [MangaQuote]
    var compact = false
    let read: (MangaQuote) -> Void
    let close: () -> Void
    /// A card for manga (default) or for books (`books: true`).
    init(books: Bool = false, compact: Bool = false, read: @escaping (MangaQuote) -> Void, close: @escaping () -> Void) {
        _quote = State(initialValue: books ? Quotes.launchBook : Quotes.launch)
        pool = books ? Quotes.books : Quotes.manga
        self.compact = compact; self.read = read; self.close = close
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule().fill(Eclipse.corona).frame(width: 3)
            VStack(alignment: .leading, spacing: 10) {
                Text("“\(quote.text)”")
                    .font(.system(compact ? .callout : .title3, design: .serif).italic().weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(quote)
                    .transition(.opacity)
                Text("\(quote.who.uppercased()) · \(quote.work.uppercased())")
                    .font(.caption2.weight(.bold)).tracking(1.2)
                    .foregroundStyle(Eclipse.highlight.opacity(0.85))
                HStack(spacing: 10) {
                    Button { read(quote) } label: {
                        Label("Read \(quote.work)", systemImage: "book.fill")
                            .font(.caption.weight(.bold)).lineLimit(1)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Eclipse.highlight, in: Capsule()).foregroundStyle(.black)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("quoteRead")
                    Button {
                        withAnimation(.snappy) {
                            var next = quote
                            while next == quote, pool.count > 1 { next = pool.randomElement() ?? quote }
                            quote = next
                        }
                    } label: {
                        Image(systemName: "shuffle").font(.caption.weight(.bold))
                            .frame(width: 30, height: 30).background(Color.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Another quote")
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close quote")
        }
        .padding(.vertical, 14).padding(.leading, 16).padding(.trailing, 10)
        .background(
            LinearGradient(colors: [Eclipse.accent.opacity(0.22), Eclipse.surface.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Eclipse.hairline))
        .contextMenu {
            Button { read(quote) } label: { Label("Read \(quote.work)", systemImage: "book") }
            Button(action: close) { Label("Close for now", systemImage: "xmark") }
        }
    }
}
