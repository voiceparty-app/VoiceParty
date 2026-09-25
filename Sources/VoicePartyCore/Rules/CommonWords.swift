import Foundation

/// A few hundred very frequent English words. Used to avoid treating ordinary words as special:
/// no learned casing for "us"/"it", no rejoining "work day", and no recognizer hints for dictionary
/// words that are one letter away from a common word ("deta" would pull "data" toward it).
public enum CommonWords {
    public static let set: Set<String> = [
        "a", "able", "about", "above", "accept", "account", "across", "act", "action", "actually", "add", "address", "after", "afternoon",
        "again", "against", "age", "ago", "agree", "ahead", "air", "all", "allow", "almost", "alone", "along", "already", "also",
        "although", "always", "am", "among", "amount", "an", "and", "animal", "another", "answer", "any", "anyone", "anything", "app",
        "appear", "apply", "are", "area", "arm", "around", "arrive", "art", "as", "ask", "at", "attention", "available", "away",
        "baby", "back", "bad", "bag", "ball", "bank", "bar", "base", "be", "beautiful", "because", "become", "bed", "been",
        "before", "begin", "behind", "being", "believe", "below", "best", "better", "between", "big", "bill", "bit", "black", "blue",
        "board", "boat", "body", "book", "both", "box", "boy", "bring", "brother", "build", "business", "busy", "but", "buy",
        "by", "call", "came", "can", "car", "card", "care", "carry", "case", "cat", "catch", "cause", "center", "certain",
        "chair", "chance", "change", "check", "child", "choose", "city", "class", "clean", "clear", "close", "code", "cold", "color",
        "come", "coming", "company", "complete", "computer", "consider", "continue", "control", "cool", "copy", "corner", "cost", "could", "count",
        "country", "couple", "course", "cover", "craft", "create", "cup", "current", "cut", "dad", "daily", "dark", "data", "date",
        "day", "dead", "deal", "dear", "decide", "deep", "deliver", "design", "desk", "detail", "did", "die", "difference", "different",
        "dinner", "direct", "do", "doctor", "does", "dog", "doing", "done", "door", "down", "draw", "dream", "dress", "drink",
        "drive", "drop", "during", "each", "early", "easy", "eat", "edge", "effect", "eight", "either", "else", "email", "end",
        "enough", "enter", "even", "evening", "event", "ever", "every", "everyone", "everything", "exactly", "example", "face", "fact", "fail",
        "fall", "family", "far", "farm", "fast", "father", "feel", "feet", "few", "field", "file", "fill", "final", "find",
        "fine", "finish", "fire", "first", "fish", "five", "fix", "floor", "fly", "follow", "food", "foot", "for", "form",
        "forward", "four", "free", "friend", "from", "front", "full", "fun", "game", "garden", "gave", "get", "girl", "give",
        "glad", "go", "going", "gold", "gone", "good", "got", "great", "green", "ground", "group", "grow", "guess", "guy",
        "had", "hair", "half", "hand", "happen", "happy", "hard", "has", "hat", "have", "he", "head", "hear", "heard",
        "heart", "heat", "help", "her", "here", "high", "him", "his", "hit", "hold", "home", "hope", "horse", "hot",
        "hour", "house", "how", "however", "huge", "human", "hundred", "i", "idea", "if", "important", "in", "inside", "instead",
        "interest", "into", "is", "issue", "it", "item", "its", "job", "join", "just", "keep", "key", "kid", "kind",
        "king", "knew", "know", "land", "language", "large", "last", "late", "later", "laugh", "lead", "learn", "least", "leave",
        "left", "leg", "less", "let", "letter", "level", "lie", "life", "light", "like", "line", "list", "listen", "little",
        "live", "long", "look", "lose", "lost", "lot", "love", "low", "made", "mail", "main", "make", "man", "many",
        "map", "mark", "market", "matter", "may", "me", "mean", "meet", "meeting", "member", "men", "message", "middle", "might",
        "mind", "minute", "miss", "mom", "money", "month", "more", "morning", "most", "mother", "move", "much", "music", "must",
        "my", "name", "near", "need", "never", "new", "news", "next", "nice", "night", "nine", "no", "none", "nor",
        "not", "note", "nothing", "notice", "now", "number", "of", "off", "offer", "office", "often", "oh", "okay", "old",
        "on", "once", "one", "only", "open", "or", "order", "other", "our", "out", "over", "own", "page", "paper",
        "part", "party", "pass", "past", "pay", "people", "person", "pick", "picture", "piece", "place", "plan", "play", "please",
        "point", "power", "present", "pretty", "price", "problem", "product", "program", "project", "put", "question", "quick", "quite", "rain",
        "rather", "reach", "read", "ready", "real", "really", "reason", "red", "remember", "report", "rest", "result", "right", "river",
        "road", "rock", "room", "round", "rule", "run", "said", "same", "saw", "say", "school", "sea", "second", "see",
        "seem", "sell", "send", "sense", "sent", "set", "seven", "several", "shall", "she", "ship", "short", "should", "show",
        "side", "sign", "simple", "since", "sing", "sit", "six", "size", "sleep", "slow", "small", "snow", "so", "some",
        "something", "sometimes", "son", "song", "soon", "sorry", "sound", "space", "speak", "special", "spend", "stand", "start", "state",
        "stay", "step", "still", "stop", "store", "story", "street", "strong", "study", "such", "sun", "sure", "system", "table",
        "take", "talk", "tax", "team", "tell", "ten", "test", "than", "thank", "thanks", "that", "the", "their", "them",
        "then", "there", "these", "they", "thing", "think", "third", "this", "those", "though", "three", "through", "time", "to",
        "today", "together", "told", "too", "took", "top", "toward", "town", "tree", "true", "try", "turn", "two", "type",
        "under", "until", "up", "upon", "us", "use", "very", "visit", "wait", "walk", "wall", "want", "war", "warm",
        "was", "watch", "water", "way", "we", "week", "well", "went", "were", "what", "when", "where", "which", "while",
        "white", "who", "whole", "why", "will", "win", "window", "with", "without", "woman", "word", "words", "work", "world",
        "would", "write", "wrong", "yeah", "year", "yes", "yet", "you", "young", "your",
    ]

    public static func contains(_ word: String) -> Bool { set.contains(word.lowercased()) }

    /// True when `word` is a common word or one edit away from one.
    public static func isNearCommon(_ word: String) -> Bool {
        let lower = word.lowercased()
        if set.contains(lower) { return true }
        guard lower.count >= 3 else { return false }
        return set.contains { abs($0.count - lower.count) <= 1 && $0.count >= 3 && TextTools.levenshtein($0, lower) <= 1 }
    }
}
