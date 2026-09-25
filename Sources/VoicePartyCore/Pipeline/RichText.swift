import Foundation

/// Lists pasted as real lists. When a dictation became a list ("first… second… third…"), an HTML version is
/// put on the clipboard next to the plain text: Notes, Mail, Gmail and Docs show real bullets/numbers, while
/// plain-text apps (terminals, editors) still get the text. Paragraph-only text stays plain, so the target
/// app's font is never changed.
public enum RichText {
    enum Block: Equatable {
        case paragraph(String)
        case numbered([String], start: Int)
        case bulleted([String])
    }

    static let numberedLine = #"^\s*(\d+)[.)]\s+(.+)$"#
    static let bulletLine = #"^\s*[-•*]\s+(.+)$"#

    /// HTML for text containing a list, or nil when there's no list (then plain text is best).
    public static func listHTML(for text: String) -> String? {
        let blocks = self.blocks(in: text)
        guard blocks.contains(where: { if case .paragraph = $0 { false } else { true } }) else { return nil }
        return blocks.map { block in
            switch block {
            case .paragraph(let text):
                return "<p>\(escape(text))</p>"
            case .numbered(let items, let start):
                let open = start == 1 ? "<ol>" : "<ol start=\"\(start)\">"
                return open + items.map { "<li>\(escape($0))</li>" }.joined() + "</ol>"
            case .bulleted(let items):
                return "<ul>" + items.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
            }
        }.joined()
    }

    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var firstLines: [String] = [] // each block's first line, as written
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            defer { if firstLines.count < blocks.count { firstLines.append(trimmed) } }
            if let (number, item) = match(numberedLine, trimmed).flatMap({ groups in Int(groups[0]).map { ($0, groups[1]) } }) {
                if case .numbered(let items, let start)? = blocks.last {
                    blocks[blocks.count - 1] = .numbered(items + [item], start: start)
                } else {
                    blocks.append(.numbered([item], start: number))
                }
            } else if let item = match(bulletLine, trimmed)?.first {
                if case .bulleted(let items)? = blocks.last {
                    blocks[blocks.count - 1] = .bulleted(items + [item])
                } else {
                    blocks.append(.bulleted([item]))
                }
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        // One item isn't a list ("- Sam" under a sign-off): it stays a line of text.
        return zip(blocks, firstLines).map { block, line in
            switch block {
            case .numbered(let items, _) where items.count == 1, .bulleted(let items) where items.count == 1: .paragraph(line)
            default: block
            }
        }
    }

    private static func match(_ pattern: String, _ line: String) -> [String]? {
        guard let re = TextTools.regex(pattern), let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let ns = line as NSString
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
