import Foundation

/// Hand-picked lines, used when the live quote databases can't be reached and mixed in with them
/// otherwise. Every series here scores well on AniList and MyAnimeList; one series is picked before
/// one of its lines, so no series turns up more often for having more quotes.
public enum CuratedQuotes {
    private static func q(_ text: String, _ who: String, _ work: String) -> LaunchQuote { LaunchQuote(text: text, who: who, work: work) }

    public static let manga: [LaunchQuote] = [
        q("You have no enemies. No one in this world has any enemies.", "Thors", "Vinland Saga"),
        q("I have no enemies.", "Thorfinn", "Vinland Saga"),
        q("In this world, is the destiny of mankind controlled by some transcendental entity or law?", "Narration", "Berserk"),
        q("The only thing humans are equal in is death.", "Johan Liebert", "Monster"),
        q("If you give up, that's when the game is over.", "Coach Anzai", "Slam Dunk"),
        q("A lesson without pain is meaningless. That's because no one can gain without sacrificing something.", "Edward Elric", "Fullmetal Alchemist"),
        q("Humankind cannot gain anything without first giving something in return.", "Alphonse Elric", "Fullmetal Alchemist"),
        q("You should enjoy the little detours to the fullest.", "Ging Freecss", "Hunter x Hunter"),
        q("I don't want to conquer anything. I just think the guy with the most freedom in this whole ocean is the Pirate King!", "Monkey D. Luffy", "One Piece"),
        q("The One Piece is real!", "Whitebeard", "One Piece"),
        q("If you win, you live. If you lose, you die. If you don't fight, you can't win!", "Eren Yeager", "Attack on Titan"),
        q("My soldiers, rage! My soldiers, scream! My soldiers, fight!", "Erwin Smith", "Attack on Titan"),
        q("I'm just a guy who's a hero for fun.", "Saitama", "One-Punch Man"),
        q("Throughout Heaven and Earth, I alone am the honored one.", "Satoru Gojo", "Jujutsu Kaisen"),
        q("Stand proud. You are strong.", "Ryomen Sukuna", "Jujutsu Kaisen"),
        q("Those who break the rules are scum, but those who abandon their friends are worse than scum.", "Kakashi Hatake", "Naruto"),
        q("Those who do not understand true pain can never understand true peace.", "Pain", "Naruto"),
        q("Admiration is the emotion furthest from understanding.", "Sosuke Aizen", "Bleach"),
        q("I am justice! I protect the innocent and those who fear evil.", "Light Yagami", "Death Note"),
        q("Set your heart ablaze.", "Kyojuro Rengoku", "Demon Slayer"),
        q("It's fine now. Why? Because I am here!", "All Might", "My Hero Academia"),
        q("Talent is something you make bloom, instinct is something you polish.", "Toru Oikawa", "Haikyuu!!"),
        q("I'm going to become the greatest general under the heavens!", "Shin", "Kingdom"),
        q("That's what Himmel the Hero would have done.", "Frieren", "Frieren: Beyond Journey's End"),
        q("I'm not the protagonist of a novel or anything. I'm just a college student who likes to read.", "Ken Kaneki", "Tokyo Ghoul"),
        q("I mustn't run away. I mustn't run away. I mustn't run away.", "Shinji Ikari", "Neon Genesis Evangelion"),
        q("In love, the one who falls first loses.", "Narration", "Kaguya-sama: Love is War"),
        q("Only I know the end of this world.", "Kim Dokja", "Omniscient Reader's Viewpoint"),
        q("Hard work never betrays you.", "Genji Kamogawa", "Hajime no Ippo"),
        q("I want to know what it means to be strong.", "Ippo Makunouchi", "Hajime no Ippo"),
        q("The only ones who should kill are those who are prepared to be killed.", "Lelouch Lamperouge", "Code Geass"),
        q("Maybe there's only a dark road up ahead. But you still have to believe and keep going.", "Kaori Miyazono", "Your Lie in April"),
        q("My magic is never giving up!", "Asta", "Black Clover"),
        q("In the name of the Moon, I'll punish you!", "Usagi Tsukino", "Sailor Moon"),
        q("It'll definitely be all right.", "Sakura Kinomoto", "Cardcaptor Sakura"),
        q("I'm gonna be King of the Pirates!", "Monkey D. Luffy", "One Piece"),
        q("I am the hope of the universe.", "Goku", "Dragon Ball"),
        q("Believe in the me that believes in you!", "Kamina", "Gurren Lagann"),
        q("Just who the hell do you think I am?!", "Kamina", "Gurren Lagann"),
        q("I'm not gonna run away, and I never go back on my word! That's my ninja way!", "Naruto Uzumaki", "Naruto"),
        q("Because I'm a genius!", "Hanamichi Sakuragi", "Slam Dunk"),
    ]

    public static let books: [LaunchQuote] = [
        q("It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.", "Jane Austen", "Pride and Prejudice"),
        q("Call me Ishmael.", "Ishmael", "Moby-Dick"),
        q("It was the best of times, it was the worst of times.", "Charles Dickens", "A Tale of Two Cities"),
        q("All happy families are alike; each unhappy family is unhappy in its own way.", "Leo Tolstoy", "Anna Karenina"),
        q("Whatever our souls are made of, his and mine are the same.", "Catherine Earnshaw", "Wuthering Heights"),
        q("I am no bird; and no net ensnares me.", "Jane Eyre", "Jane Eyre"),
        q("Beware; for I am fearless, and therefore powerful.", "The Creature", "Frankenstein"),
        q("Listen to them, the children of the night. What music they make!", "Count Dracula", "Dracula"),
        q("The only way to get rid of a temptation is to yield to it.", "Lord Henry", "The Picture of Dorian Gray"),
        q("It's no use going back to yesterday, because I was a different person then.", "Alice", "Alice's Adventures in Wonderland"),
        q("When you have eliminated the impossible, whatever remains, however improbable, must be the truth.", "Sherlock Holmes", "The Sign of the Four"),
        q("All human wisdom is contained in these two words: wait and hope.", "Edmond Dantès", "The Count of Monte Cristo"),
        q("So we beat on, boats against the current, borne back ceaselessly into the past.", "Nick Carraway", "The Great Gatsby"),
        q("I'm not afraid of storms, for I'm learning how to sail my ship.", "Amy March", "Little Women"),
        q("Tomorrow is always fresh, with no mistakes in it yet.", "Anne Shirley", "Anne of Green Gables"),
        q("To be, or not to be, that is the question.", "Hamlet", "Hamlet"),
        q("All we have to decide is what to do with the time that is given us.", "Gandalf", "The Fellowship of the Ring"),
        q("In a hole in the ground there lived a hobbit.", "J.R.R. Tolkien", "The Hobbit"),
        q("Fear is the mind-killer.", "Paul Atreides", "Dune"),
        q("Live for more.", "Eo", "Red Rising"),
        q("Break the chains.", "Darrow", "Red Rising"),
        q("Life before death. Strength before weakness. Journey before destination.", "The First Ideal", "The Way of Kings"),
        q("There's always another secret.", "Kelsier", "Mistborn"),
        q("Fist my bump.", "Rocky", "Project Hail Mary"),
        q("Don't Panic.", "Douglas Adams", "The Hitchhiker's Guide to the Galaxy"),
        q("So it goes.", "Kurt Vonnegut", "Slaughterhouse-Five"),
        q("It was a bright cold day in April, and the clocks were striking thirteen.", "George Orwell", "1984"),
        q("It was a pleasure to burn.", "Ray Bradbury", "Fahrenheit 451"),
        q("The man in black fled across the desert, and the gunslinger followed.", "Stephen King", "The Gunslinger"),
        q("May the odds be ever in your favor.", "Effie Trinket", "The Hunger Games"),
        q("It is our choices that show what we truly are, far more than our abilities.", "Albus Dumbledore", "Harry Potter and the Chamber of Secrets"),
    ]

    /// A random line from each series, series in random order.
    public static func shuffled(_ list: [LaunchQuote]) -> [LaunchQuote] {
        Dictionary(grouping: list, by: \.work).values.shuffled().compactMap { $0.randomElement() }
    }
}
