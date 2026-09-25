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

    /// Same Soundex code, treating any leading vowel as equivalent ("Ayla" ≈ "Eila").
    public static func soundsAlike(_ a: String, _ b: String) -> Bool {
        guard a.count >= 4, b.count >= 4 else { return false }
        let ca = soundex(a), cb = soundex(b)
        guard !ca.isEmpty, ca.dropFirst() == cb.dropFirst(), ca.dropFirst() != "000" else { return false }
        let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
        return ca.first == cb.first || (vowels.contains(ca.first!) && vowels.contains(cb.first!))
    }
}
