import Foundation

/// Sound-alike matching for names and jargon the recognizer spells differently ("Katherine" / "Kathryn").
public enum Phonetic {
    /// American Soundex (first letter + three digits).
    public static func soundex(_ word: String) -> String {
        let letters = word.uppercased().filter { $0.isLetter && $0.isASCII }
        guard let first = letters.first else { return "" }
        func code(_ c: Character) -> Character? {
            switch c {
            case "B", "F", "P", "V": "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": "2"
            case "D", "T": "3"
            case "L": "4"
            case "M", "N": "5"
            case "R": "6"
            default: nil // vowels, H, W, Y
            }
        }
        var result = String(first)
        var previous = code(first)
        for c in letters.dropFirst() {
            let digit = code(c)
            if let digit, digit != previous { result.append(digit) }
            if c != "H" && c != "W" { previous = digit }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    /// The consonant sounds of a word, in order: spelling digraphs read as one sound ("ph" f, "ck" k, soft "c" s),
    /// voiced and voiceless pairs merged (d/t, b/p, g/k, v/f, z/s: recognizers swap them most), h, w, y and vowels
    /// dropped, repeats collapsed. "Holtavi" and "Lotavi" are both l-t-f; "Feelco" and "Filco" f-l-k.
    public static func consonants(_ word: String) -> String {
        var w = word.lowercased().filter { $0.isLetter && $0.isASCII }
        for (spelling, sound) in [("tch", "C"), ("sch", "sk"), ("ph", "f"), ("gh", ""), ("ck", "k"), ("sh", "S"), ("ch", "C"),
                                  ("th", "T"), ("wh", "w"), ("qu", "kw"), ("dg", "j"), ("kn", "n"), ("wr", "r"), ("x", "ks"), ("q", "k")] {
            w = w.replacingOccurrences(of: spelling, with: sound)
        }
        let letters = Array(w)
        var out = ""
        for (i, letter) in letters.enumerated() {
            let next = i + 1 < letters.count ? letters[i + 1] : nil
            let sound: Character
            switch letter {
            case "a", "e", "i", "o", "u", "y", "h", "w": continue
            case "c": sound = next.map { "eiy".contains($0) } == true ? "s" : "k"
            case "g": sound = next.map { "eiy".contains($0) } == true ? "j" : "k"
            case "z": sound = "s"
            case "v": sound = "f"
            case "d": sound = "t"
            case "b": sound = "p"
            default: sound = letter
            }
            if out.last != sound { out.append(sound) }
        }
        return out
    }

    /// Spoken syllables, roughly: groups of vowel letters, less a silent final "e" ("Feelco" 2, "Holtavi" 3, "mile" 1).
    public static func syllables(_ word: String) -> Int {
        let w = Array(word.lowercased().filter { $0.isLetter && $0.isASCII })
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0
        for (i, letter) in w.enumerated() where vowels.contains(letter) && (i == 0 || !vowels.contains(w[i - 1])) { count += 1 }
        if count > 1, w.last == "e", w.count >= 2, !vowels.contains(w[w.count - 2]), w[w.count - 2] != "l" { count -= 1 }
        return count
    }

    /// The same consonant sounds (at least three) in the same number of syllables: how a name the recognizer didn't
    /// know comes out ("Holtavi" as "Lotavi", "Feelco" as "Filco"), when its spelling and even first letter differ.
    public static func sameShape(_ a: String, _ b: String) -> Bool {
        let ca = consonants(a)
        return ca.count >= 3 && ca == consonants(b) && syllables(a) == syllables(b)
    }

    /// Same Soundex code, treating any leading vowel as equivalent ("Ayla" ≈ "Eila").
    public static func soundsAlike(_ a: String, _ b: String) -> Bool {
        guard a.count >= 4, b.count >= 4 else { return false }
        let ca = soundex(a), cb = soundex(b)
        guard !ca.isEmpty, ca.dropFirst() == cb.dropFirst(), ca.dropFirst() != "000" else { return false }
        let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
        return ca.first == cb.first || (vowels.contains(ca.first!) && vowels.contains(cb.first!))
    }
}
