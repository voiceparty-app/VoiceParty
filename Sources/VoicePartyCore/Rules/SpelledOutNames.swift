import Foundation

/// Recognizers that don't know a name sometimes write it as capital letters: Parakeet hears "Tamaro"
/// and writes "TMRO". A capitalized token matches a dictionary word when it is that word with some vowels
/// dropped (same first and last letter), it is at least four letters, and it isn't a well-known acronym.
public enum SpelledOutNames {
    static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// Acronyms people really say; never turned into dictionary words ("JSON" is not "Jason").
    static let knownAcronyms: Set<String> = [
        "ajax", "aida", "aids", "amex", "asap", "avid", "bios", "cmos", "covid", "csat", "dmca", "ebit", "ecmo", "fifo",
        "fomo", "gdpr", "gpio", "html", "http", "https", "hvac", "icann", "imho", "iirc", "jpeg", "json", "lifo", "lgbt",
        "llms", "mapi", "mits", "nasa", "nato", "nasdaq", "nimby", "oled", "opec", "raid", "saas", "paas", "iaas", "scuba",
        "smtp", "sonar", "tldr", "toml", "unesco", "unicef", "yaml", "yolo", "xhtml", "cobol", "fortran", "posix",
        "wysiwyg", "ascii", "mpeg", "nimh", "okrs", "kpis", "ipos", "ceos", "ctos", "apis", "gifs", "pdfs", "urls", "faqs",
        "leds", "lcds", "suvs", "atms", "dvds", "mvps", "roth", "unix", "linux", "cuda", "vram", "sram", "dram", "nand",
        "ecma", "mysql", "nosql", "ieee", "isbn", "inri", "hipaa", "ferpa", "osha", "fema", "doge", "ncaa", "nfl", "wnba",
        "saml", "wasm", "cors", "csrf", "oidc", "oauth", "scim", "ldap", "imap", "grpc", "rest", "soap", "yaml", "jwt", "sqlite",
        "nginx", "http2", "cdns", "dmarc", "dkim", "spf", "smtp", "ssml", "wcag", "aria", "ansi", "utf", "ascii", "unicode",
        "gpus", "cpus", "tpus", "ssds", "nvme", "raid", "vlan", "ipsec", "vpns", "dhcp", "ntp", "snmp", "arpa", "darpa",
        "fifa", "uefa", "unesco", "nasdaq", "ftse", "saas", "paas", "iaas", "b2b", "b2c", "roi", "kpi", "okr", "gaap", "ifrs",
    ]

    /// Whether `token` (all capitals) is `term` with vowels dropped: "TMRO" → "Tamaro".
    public static func matches(_ token: String, term: String) -> Bool {
        let t = Array(token.lowercased()), w = Array(term.lowercased())
        guard t.count >= 4, w.count > t.count, w.count - t.count <= 3,
              t.first == w.first, t.last == w.last,
              token.allSatisfy(\.isUppercase), token.allSatisfy(\.isLetter), w.allSatisfy(\.isLetter),
              !knownAcronyms.contains(String(t)) else { return false }
        // Walk the word; every letter the token skips must be a vowel.
        var i = 0
        for letter in w {
            if i < t.count && t[i] == letter { i += 1 }
            else if !vowels.contains(letter) { return false }
        }
        return i == t.count
    }

    /// Dictionary words that can be spelled out: single names in their own casing, not common words or acronyms.
    public static func isCandidate(_ phrase: String) -> Bool {
        guard phrase.count >= 5, !phrase.contains(" "), phrase.allSatisfy(\.isLetter),
              phrase.first?.isUppercase == true, phrase.dropFirst().contains(where: \.isLowercase) else { return false }
        return !CommonWords.isNearCommon(phrase)
    }

    /// All-capital tokens in `text` (with their ranges), e.g. "TMRO" in "the DLCO meeting".
    static func capitalTokens(in text: String) -> [(token: String, range: NSRange)] {
        guard let re = TextTools.regex(#"(?<![\p{L}\p{N}])\p{Lu}{4,}(?![\p{L}\p{N}])"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range), $0.range) }
    }

    /// Replaces spelled-out tokens with the dictionary word they stand for.
    public static func apply(_ text: String, terms: [String]) -> (text: String, replaced: [String]) {
        let candidates = terms.filter(isCandidate)
        guard !candidates.isEmpty else { return (text, []) }
        var out = text
        var replaced: [String] = []
        for (token, range) in capitalTokens(in: text).reversed() {
            let found = candidates.filter { matches(token, term: $0) }
            guard found.count == 1, let term = found.first, let r = Range(range, in: out) else { continue }
            out.replaceSubrange(r, with: term)
            replaced.append(term)
        }
        return (out, replaced)
    }
}

/// Names the recognizer heard as other words or spelled differently: "loop wize", "Loopwize",
/// "Loop Wize" → "Loopwise". Deterministic because small models often ignore the hint. Only for
/// dictionary names with their own casing, and only for close, same-sounding spellings.
public enum SoundAlikeNames {
    /// Replaces word runs (1…n+1 words, no punctuation between) that are a near spelling of `term`.
    /// Dictionary words this applies to: names with their own casing, 6+ letters, not (near) common words.
    public static func isCandidate(_ term: String) -> Bool {
        term.filter(\.isLetter).count >= 6 && term.allSatisfy({ $0.isLetter || $0 == " " }) && term.contains(where: \.isUppercase)
            && !CommonWords.isNearCommon(term)
    }

    /// `term` must pass `isCandidate` (checked once by the caller, not per dictation).
    public static func apply(_ text: String, term: String, isEnglishWord: (String) -> Bool = { CommonWords.contains($0) }) -> (text: String, count: Int) {
        let goal = term.lowercased().filter(\.isLetter)
        guard let re = TextTools.regex(#"[\p{L}]+"#) else { return (text, 0) }
        let termWords = term.split(separator: " ").count
        // A one-word name only ever replaces one heard word, and never an ordinary one ("share on" is not
        // "Sharon", "brand" is not "Brandt"). Multi-word names ("Wispr Flow") may be heard as ordinary words.
        let maxWidth = termWords == 1 ? 1 : termWords + 1
        let ns = text as NSString
        let words = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        var replacements: [NSRange] = []
        var index = 0
        while index < words.count {
            var matched: NSRange?
            for width in stride(from: min(maxWidth, words.count - index), through: 1, by: -1) {
                let window = Array(words[index..<(index + width)])
                // Words must be adjacent: only spaces between them.
                let adjacent = zip(window.dropLast(), window.dropFirst()).allSatisfy { a, b in
                    ns.substring(with: NSRange(location: a.upperBound, length: b.location - a.upperBound)).allSatisfy { $0 == " " }
                }
                guard adjacent, let first = window.first, let last = window.last else { continue }
                let range = NSRange(location: first.location, length: last.upperBound - first.location)
                if isEmbedded(range, in: ns) { continue } // part of tamaro_client, /srv/tamaro, tamaro.io
                let found = ns.substring(with: range)
                let heard = found.lowercased().filter(\.isLetter)
                guard found != term, heard.first == goal.first, !(termWords == 1 && isEnglishWord(heard)),
                      !(heard.hasPrefix(goal) && heard.count > goal.count), // plurals/possessives: "Marias"
                      heard == goal || (TextTools.similarity(heard, goal) >= 0.8 && Phonetic.soundsAlike(heard, goal)),
                      !found.split(separator: " ").allSatisfy({ CommonWords.contains(String($0)) }) else { continue }
                matched = range
                index += width
                break
            }
            if let matched { replacements.append(matched) } else { index += 1 }
        }
        var out = text
        for range in replacements.reversed() {
            if let r = Range(range, in: out) { out.replaceSubrange(r, with: term) }
        }
        return (out, replacements.count)
    }

    /// Letters inside an identifier, path, address or domain aren't a spoken word.
    static func isEmbedded(_ range: NSRange, in text: NSString) -> Bool {
        let glue = CharacterSet(charactersIn: "_/@\\").union(.decimalDigits)
        func scalar(_ at: Int) -> Unicode.Scalar? {
            guard at >= 0, at < text.length else { return nil }
            return Unicode.Scalar(text.character(at: at))
        }
        if let before = scalar(range.location - 1), glue.contains(before) || before == "." && scalar(range.location - 2).map(CharacterSet.alphanumerics.contains) == true {
            return true
        }
        if let after = scalar(range.upperBound) {
            if glue.contains(after) { return true }
            if after == ".", let next = scalar(range.upperBound + 1), CharacterSet.alphanumerics.contains(next) { return true }
        }
        return false
    }
}
