import Foundation

/// Decides whether pasting makes sense from what Accessibility says about the focused element.
public enum FocusClassifier {
    public enum Decision: Equatable, Sendable {
        /// A text input: paste.
        case paste
        /// Definitely not a text input (a list, a button…): keep the text on the clipboard instead.
        case copyOnly
        /// Can't tell (Electron and custom views often report generic roles): paste and hope.
        case unknown
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea", "AXSecureTextField"]
    static let nonTextRoles: Set<String> = [
        "AXOutline", "AXList", "AXTable", "AXButton", "AXImage", "AXMenuItem", "AXMenuButton", "AXCheckBox",
        "AXRadioButton", "AXSlider", "AXCell", "AXRow", "AXPopUpButton", "AXTabGroup", "AXDisclosureTriangle",
    ]

    public static func decide(role: String?, valueSettable: Bool?, editable: Bool?) -> Decision {
        if let role, textRoles.contains(role) { return .paste }
        if valueSettable == true || editable == true { return .paste }
        if let role, nonTextRoles.contains(role) { return .copyOnly }
        return .unknown
    }
}

/// Variable recognition: spoken words → identifiers seen in the editor
/// ("get user by id" → getUserById, "user service dot ts" → userService.ts).
public struct IdentifierMatcher: Sendable {
    struct Entry: Sendable {
        let identifier: String
        let regex: NSRegularExpression
        let length: Int
        /// Two ordinary words ("is empty", "for each", "file name") are only code when you say so.
        let needsCue: Bool
    }

    /// Words that mark the next (or previous) words as code: "call fetch user", "the file name variable".
    static let cues: Set<String> = ["call", "calls", "calling", "function", "func", "method", "variable", "var", "property", "field",
                                    "param", "parameter", "argument", "arg", "prop", "hook", "const", "let", "constant", "enum", "class", "struct"]

    private let entries: [Entry]

    /// `isEnglishWord`: the app passes Apple's vocabulary; two everyday words need a code cue to become an identifier.
    public init(known: [String], isEnglishWord: (String) -> Bool = { _ in false }) {
        var entries: [Entry] = []
        for identifier in Set(known) {
            let (words, fileExtension) = Self.spokenParts(identifier)
            guard words.count + (fileExtension == nil ? 0 : 1) >= 2 else { continue }
            var pattern = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"[\s_\-]*"#)
            if let fileExtension {
                pattern += #"(?:\s*\.\s*|\s+dot\s+)"# + NSRegularExpression.escapedPattern(for: fileExtension)
            }
            let full = #"(?<![\p{L}\p{N}_])"# + pattern + #"(?![\p{L}\p{N}_])"#
            if let regex = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]) {
                let ordinary = fileExtension == nil && words.count == 2 && words.allSatisfy { CommonWords.contains($0) || isEnglishWord($0) }
                entries.append(Entry(identifier: identifier, regex: regex, length: words.count, needsCue: ordinary))
            }
        }
        self.entries = entries.sorted { $0.length > $1.length }
    }

    /// Splits camelCase, PascalCase, snake_case, kebab-case and a file extension into spoken words.
    static func spokenParts(_ identifier: String) -> (words: [String], fileExtension: String?) {
        var base = identifier
        var fileExtension: String?
        if let dot = identifier.lastIndex(of: "."), dot != identifier.startIndex {
            let ext = String(identifier[identifier.index(after: dot)...])
            if !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                fileExtension = ext.lowercased()
                base = String(identifier[..<dot])
            }
        }
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in base {
            if ch == "_" || ch == "-" || ch == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if ch.isUppercase, let p = previous, p.isLowercase || p.isNumber {
                if !current.isEmpty { words.append(current) }
                current = String(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return (words.map { $0.lowercased() }, fileExtension)
    }

    public func apply(_ text: String) -> String {
        var out = text
        for entry in entries {
            let ns = out as NSString
            for match in entry.regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                if entry.needsCue {
                    let before = ns.substring(to: match.range.location).split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() }
                    let after = ns.substring(from: match.range.upperBound).split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() }
                    guard [before, after].contains(where: { $0.map(Self.cues.contains) == true }) else { continue }
                }
                if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: entry.identifier) }
            }
        }
        return out
    }
}
