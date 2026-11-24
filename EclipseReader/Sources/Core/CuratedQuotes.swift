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

    /// A random line from each series, series in random order.
    public static func shuffled(_ list: [LaunchQuote]) -> [LaunchQuote] {
        Dictionary(grouping: list, by: \.work).values.shuffled().compactMap { $0.randomElement() }
    }
}
