import Foundation

/// Fixes recognizer homophones only where the surrounding words make the intent unambiguous
/// ("the system as a hole" → "as a whole", "better then" → "better than"). Every rule is anchored on
/// context so correct uses ("a hole in the wall", "and then we ship") are never touched.
public struct HomophoneFixer: Sendable {
    public init() {}

    static let rules: [(pattern: String, template: String)] = [
        (#"\bas a hole\b(?!\s+in\b)"#, "as a whole"),
        (#"\bon the hole\b(?=\s*,)"#, "on the whole"),
        (#"\bthe hole (thing|point|time|day|week|month|year|team|project|system|process|idea|story|world|company|reason|family|night|app|product|house|place)\b"#, "the whole $1"),
        (#"\ba hole (lot|bunch|new|other|different)\b"#, "a whole $1"),
        // "Their will…" can be a testament; only the unambiguous verbs.
        (#"\btheir (is|are|was|were|isn't|aren't|wasn't)\b"#, "there $1"),
        // A comparison needs something to compare with: "better then that", not "more then." or "worse then better".
        (#"\b(better|more|less|rather|other|greater|larger|smaller|faster|slower|higher|lower|easier|harder|bigger|worse|longer|shorter|cheaper) then(?=\s+(?!(?:better|worse|more|less|then|again|later|now|so|and|but|or|we|i|you|they|he|she)\b)[\p{L}\p{N}])"#, "$1 than"),
        (#"(?<!\bfor )(?<!\bof )(?<!\bto )\byour welcome\b(?!\s+(?:email|message|page|screen|packet|kit|note|video|letter|gift|bag|party|speech|flow|mat))"#, "you're welcome"),
        (#"(?<!\bthe )\b(could|would|should|must|might) of\b"#, "$1 have"),
        (#"(?<!\bof )(?<!\bhit )(?<!\breached )\bits (been|a|an|not|going|just|okay|ok|fine|done|all|so|really|always|never|also|getting|gonna)\b(?![-’'])"#, "it's $1"),
        (#"\b(way|far) to (much|many|long|late|early|big|small|hard|easy|fast|slow|expensive|complicated)\b(?!-)"#, "$1 too $2"),
        (#"\b(can|could|will|would|please|to) right (a|an|the|this|that|it|down|me|up|some)\b(?!\s+(?:ship|wrong|wrongs|record|course)\b)"#, "$1 write $2"),
    ]

    public func fix(_ text: String) -> String {
        var out = text
        for rule in Self.rules {
            guard let re = TextTools.regex(rule.pattern) else { continue }
            let ns = out as NSString
            for match in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                var replacement = re.replacementString(for: match, in: out, offset: 0, template: rule.template)
                // Keep a leading capital ("Their is" → "There is", "Its been" → "It's been").
                if ns.substring(with: match.range).first?.isUppercase == true {
                    replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
                }
                if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: replacement) }
            }
        }
        return out
    }
}
