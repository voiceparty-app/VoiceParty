import Foundation

/// Vibe-coding helpers: spoken file names become real ones ("index dot tsx" → "index.tsx"),
/// optionally tagged for AI chat in Cursor/Windsurf ("@index.tsx").
public struct CodeFormatter: Sendable {
    public static let extensions = [
        "tsx", "ts", "jsx", "js", "mjs", "py", "swift", "md", "json", "yaml", "yml", "rs", "go", "rb", "java", "kt",
        "css", "scss", "html", "sh", "txt", "toml", "c", "cpp", "h", "m", "sql", "vue", "svelte", "env", "lock", "xml",
    ]

    /// File names already visible in the editor (tab titles, window title), used to confirm matches.
    public var knownFiles: [String]
    public var tagFiles: Bool

    public init(knownFiles: [String] = [], tagFiles: Bool = false) {
        self.knownFiles = knownFiles
        self.tagFiles = tagFiles
    }

    /// Framework names written like files ("Node.js") that must not be @-tagged.
    static let notFiles: Set<String> = ["node.js", "vue.js", "next.js", "nuxt.js", "react.js", "express.js", "three.js",
                                        "d3.js", "chart.js", "ember.js", "angular.js", "backbone.js", "p5.js", "socket.io"]
    static let dotfiles = ["env", "gitignore", "npmrc", "zshrc", "bashrc", "prettierrc", "eslintrc", "editorconfig", "dockerignore", "nvmrc"]

    /// Extensions that are also web domains ("docs.rs", "brew.sh"): tagged only when the file is on screen or spoken.
    static let domainLike: Set<String> = ["rs", "sh", "md", "py", "go", "io"]

    public func apply(_ text: String) -> String {
        var out = text
        let ext = Self.extensions.joined(separator: "|")
        // Files spoken as "main dot rs" are files, whatever their extension.
        let spoken = Set(TextTools.matches(of: #"\b([A-Za-z0-9_\-]+)\s+dot\s+("# + ext + #")\b"#, in: text).map { "\($0[0]).\($0[1])".lowercased() })
        // "the dot env file" → ".env"
        out = TextTools.replacing(out, pattern: #"\bdot\s+("# + Self.dotfiles.joined(separator: "|") + #")\b"#, with: ".$1")
        // "index dot tsx" / "index.TSX" → "index.tsx"
        out = TextTools.replacing(out, pattern: #"\b([A-Za-z0-9_\-]+)\s+dot\s+("# + ext + #")\b"#, with: "$1.$2")
        if let re = TextTools.regex(#"(?<![\w.@/])([A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)*)\.("# + ext + #")\b"#) {
            let ns = out as NSString
            for match in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let name = ns.substring(with: match.range(at: 1))
                let fileExt = ns.substring(with: match.range(at: 2)).lowercased()
                if name.count == 1 && fileExt.count == 1 { continue } // "5 p.m.", not a file
                var file = "\(name).\(fileExt)"
                let known = knownFiles.first(where: { $0.caseInsensitiveCompare(file) == .orderedSame })
                if let known { file = known }
                let before = match.range.location > 0 ? ns.substring(with: NSRange(location: match.range.location - 1, length: 1)) : ""
                let isFile = known != nil || spoken.contains(file.lowercased()) || !Self.domainLike.contains(fileExt)
                if tagFiles && isFile && before != "@" && before != "/" && !Self.notFiles.contains(file.lowercased()) { file = "@" + file }
                if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: file) }
            }
        }
        return out
    }

    /// File names that appear in text (e.g. a window title "AppModel.swift — VoiceParty").
    public static func fileNames(in text: String) -> [String] {
        let ext = extensions.joined(separator: "|")
        guard let re = TextTools.regex(#"\b[A-Za-z0-9_\-]+\.(?:"# + ext + #")\b"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
