import SwiftUI

/// One short line from manga, manhwa and anime-adjacent classics, shown on the library at each launch.
struct MangaQuote: Hashable, Sendable {
    let text: String
    let who: String
    let work: String
}

enum Quotes {
    static let all: [MangaQuote] = [
        MangaQuote(text: "In this world, is the destiny of mankind controlled by some transcendental entity or law?", who: "Narration", work: "Berserk"),
        MangaQuote(text: "Arise.", who: "Sung Jinwoo", work: "Solo Leveling"),
        MangaQuote(text: "If you win, you live. If you lose, you die. If you don't fight, you can't win!", who: "Eren Yeager", work: "Attack on Titan"),
        MangaQuote(text: "A lesson without pain is meaningless.", who: "Edward Elric", work: "Fullmetal Alchemist"),
        MangaQuote(text: "Fear is not evil. It tells you what your weakness is.", who: "Gildarts Clive", work: "Fairy Tail"),
        MangaQuote(text: "Hard work is worthless for those that don't believe in themselves.", who: "Naruto Uzumaki", work: "Naruto"),
        MangaQuote(text: "You should enjoy the little detours to the fullest.", who: "Ging Freecss", work: "Hunter × Hunter"),
        MangaQuote(text: "Throughout Heaven and Earth, I alone am the honored one.", who: "Satoru Gojo", work: "Jujutsu Kaisen"),
        MangaQuote(text: "Stand proud. You are strong.", who: "Ryomen Sukuna", work: "Jujutsu Kaisen"),
        MangaQuote(text: "Set your heart ablaze.", who: "Kyojuro Rengoku", work: "Demon Slayer"),
        MangaQuote(text: "Surpass your limits. Right here, right now!", who: "Yami Sukehiro", work: "Black Clover"),
        MangaQuote(text: "Being weak is nothing to be ashamed of. Staying weak is.", who: "Fuegoleon Vermillion", work: "Black Clover"),
        MangaQuote(text: "I'll leave tomorrow's problems to tomorrow's me.", who: "Saitama", work: "One-Punch Man"),
        MangaQuote(text: "People's lives don't end when they die. It ends when they lose faith.", who: "Itachi Uchiha", work: "Naruto"),
        MangaQuote(text: "If you don't take risks, you can't create a future.", who: "Monkey D. Luffy", work: "One Piece"),
    ]
    /// Picked once per launch.
    static let launch = all.randomElement() ?? all[0]
}

/// The launch quote: big serif line, eclipse-coloured rule. "Read" takes you to the series it's
/// from (your library, or a search of every site), the shuffle button picks another, × closes it.
struct QuoteCard: View {
    @State private var quote = Quotes.launch
    var compact = false
    let read: (MangaQuote) -> Void
    let close: () -> Void
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
                            while next == quote, Quotes.all.count > 1 { next = Quotes.all.randomElement() ?? quote }
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
