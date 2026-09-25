import AppKit
import ApplicationServices
import NaturalLanguage
import VoicePartyCore

/// Reads what's around the cursor through Accessibility — locally, once per dictation, never stored.
enum ContextReader {
    struct Snapshot {
        var context: DictationContext
        /// The focused element, kept for learning from the user's edits after pasting.
        var focusedElement: AXUIElement?
        /// A password field: the dictation leaves no trace (see DictationPrivacy).
        var isSecureField = false
    }

    static func snapshot(includeText: Bool, overrides: [String: AppCategory]) -> Snapshot {
        let app = NSWorkspace.shared.frontmostApplication
        var context = DictationContext(appBundleID: app?.bundleIdentifier, appName: app?.localizedName)
        var focusedElement: AXUIElement?
        var isSecureField = false

        if let pid = app?.processIdentifier {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.2)
            // Chromium/Electron apps only build their accessibility tree when asked.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            if let window: AXUIElement = copy(appElement, kAXFocusedWindowAttribute) {
                // Titles can hold email subjects and document names: only read with Context awareness on.
                if includeText { context.windowTitle = copy(window, kAXTitleAttribute) }
                context.url = (copy(window, kAXDocumentAttribute) as String?).flatMap { $0.hasPrefix("http") ? $0 : nil }
            }
            if let element: AXUIElement = copy(appElement, kAXFocusedUIElementAttribute) {
                focusedElement = element
                let role: String? = copy(element, kAXRoleAttribute)
                let subrole: String? = copy(element, kAXSubroleAttribute)
                let isSecure = subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
                isSecureField = isSecure
                if context.url == nil { context.url = webURL(near: element) }
                if includeText && !isSecure {
                    readText(around: element, into: &context)
                }
            }
        }

        context.category = AppCategorizer.category(bundleID: context.appBundleID, url: context.url, overrides: overrides)
        // Terms are extracted by the caller on the main thread (NSSpellChecker isn't thread-safe).
        return Snapshot(context: context, focusedElement: focusedElement, isSecureField: isSecureField)
    }

    /// Selected text in the focused element, if any.
    static func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        let text: String? = copy(element, kAXSelectedTextAttribute)
        return text?.isEmpty == false ? text : nil
    }

    static func focusedElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        return copy(appElement, kAXFocusedUIElementAttribute)
    }

    /// Full text value of an element (used to watch for edits after pasting).
    static func value(of element: AXUIElement) -> String? {
        copy(element, kAXValueAttribute)
    }

    // MARK: - Private

    private static func readText(around element: AXUIElement, into context: inout DictationContext) {
        context.selectedText = (copy(element, kAXSelectedTextAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
        guard let value: String = copy(element, kAXValueAttribute) else { return }
        let ns = value as NSString
        var caret = ns.length
        if let rangeValue: AXValue = copy(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) { caret = min(max(0, range.location), ns.length) }
        }
        let beforeStart = max(0, caret - 1500)
        context.textBeforeCursor = ns.substring(with: NSRange(location: beforeStart, length: caret - beforeStart))
        let afterLength = min(500, ns.length - caret)
        if afterLength > 0 { context.textAfterCursor = ns.substring(with: NSRange(location: caret, length: afterLength)) }
    }

    /// Browsers expose the page URL on the web area.
    private static func webURL(near element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let node = current else { return nil }
            if let role: String = copy(node, kAXRoleAttribute), role == "AXWebArea" {
                if let url: URL = copy(node, kAXURLAttribute) { return url.absoluteString }
                if let url: String = copy(node, kAXURLAttribute) { return url }
            }
            current = copy(node, kAXParentAttribute)
        }
        return nil
    }

    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
}

/// Maps the frontmost app (and site, in browsers) to a category for styles and Insights.
enum AppCategorizer {
    static let bundleCategories: [String: AppCategory] = [
        // Email
        "com.apple.mail": .email, "com.microsoft.Outlook": .email, "com.superhuman.electron": .email,
        "com.readdle.smartemail-Mac": .email, "com.readdle.SparkDesktop": .email, "it.bloop.airmail2": .email,
        // Work messengers
        "com.tinyspeck.slackmacgap": .workMessage, "com.microsoft.teams2": .workMessage, "com.microsoft.teams": .workMessage,
        "com.hnc.Discord": .workMessage, "us.zoom.xos": .workMessage, "com.linear": .workMessage,
        // Personal messengers
        "com.apple.MobileSMS": .personalMessage, "net.whatsapp.WhatsApp": .personalMessage, "WhatsApp": .personalMessage,
        "ru.keepcoder.Telegram": .personalMessage, "org.whispersystems.signal-desktop": .personalMessage,
        "com.facebook.archon": .personalMessage, "com.tencent.xinWeChat": .personalMessage,
        // AI apps
        "com.openai.chat": .aiPrompt, "com.anthropic.claudefordesktop": .aiPrompt, "com.perplexity.mac": .aiPrompt,
        "com.google.GeminiMacOS": .aiPrompt, "com.openai.codex": .aiPrompt, "com.anysphere.sand": .code,
        // Documents & notes
        "com.apple.Notes": .document, "com.apple.iWork.Pages": .document, "com.microsoft.Word": .document,
        "md.obsidian": .document, "notion.id": .document, "com.apple.TextEdit": .document, "com.craft.craft": .document,
        "net.shinyfrog.bear": .document,
        // Code
        "com.microsoft.VSCode": .code, "com.todesktop.230313mzl4w4u92": .code, "com.exafunction.windsurf": .code,
        "com.apple.dt.Xcode": .code, "dev.zed.Zed": .code, "com.jetbrains.intellij": .code, "com.sublimetext.4": .code,
        // Terminals
        "com.apple.Terminal": .terminal, "com.googlecode.iterm2": .terminal, "dev.warp.Warp-Stable": .terminal,
        "com.mitchellh.ghostty": .terminal, "net.kovidgoyal.kitty": .terminal,
    ]

    static let urlCategories: [(String, AppCategory)] = [
        ("mail.google.com", .email), ("outlook.live.com", .email), ("outlook.office.com", .email),
        ("app.slack.com", .workMessage), ("teams.microsoft.com", .workMessage), ("discord.com", .workMessage),
        ("web.whatsapp.com", .personalMessage), ("messenger.com", .personalMessage), ("web.telegram.org", .personalMessage),
        ("chatgpt.com", .aiPrompt), ("claude.ai", .aiPrompt), ("gemini.google.com", .aiPrompt), ("perplexity.ai", .aiPrompt),
        ("docs.google.com", .document), ("notion.so", .document), ("github.com", .code),
    ]

    static func category(bundleID: String?, url: String?, overrides: [String: AppCategory]) -> AppCategory {
        if let bundleID, let override = overrides[bundleID] { return override }
        if let url = url?.lowercased(), let hit = urlCategories.first(where: { url.contains($0.0) }) { return hit.1 }
        if let bundleID, let known = bundleCategories[bundleID] { return known }
        return .other
    }
}

/// Pulls names and jargon out of nearby text to bias recognition and cleanup.
enum TermExtractor {
    /// Terms from a snapshot's surrounding text. Main thread only.
    @MainActor
    static func terms(for context: DictationContext) -> [String] {
        let source = [context.textBeforeCursor, context.textAfterCursor, context.windowTitle].compactMap { $0 }.joined(separator: "\n")
        return terms(in: source, codeMode: context.category == .code || context.category == .terminal)
    }

    /// Apple's English vocabulary (~57k everyday words; ~4 MB, loaded once): unlike the spell checker, it
    /// doesn't learn the user's names, so it tells "Kubernetes" (a name) from "Settings" (a word).
    nonisolated(unsafe) static let englishWords = NLEmbedding.wordEmbedding(for: .english)

    /// An everyday English word (every part of a hyphenated one: "Double-tap", "Auto-learned").
    /// Safe from any thread (the dictation pipeline runs off the main thread).
    @Sendable static func isEnglishWord(_ word: String) -> Bool {
        guard let englishWords else { return false }
        let parts = word.lowercased().split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in CommonWords.contains(part) || englishLock.withLock { englishWords.contains(part) } }
    }
    private static let englishLock = NSLock()

    static func terms(in text: String, codeMode: Bool, limit: Int = 40) -> [String] {
        guard !text.isEmpty else { return [] }
        var scores: [String: Int] = [:]

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [.personalName, .organizationName, .placeName].contains(tag), text[range].count >= 3 {
                let name = String(text[range])
                // The tagger calls some ordinary words names ("Speak" at the start of a line): a one-word
                // name must not be an everyday English word.
                if name.contains(" ") || !isEnglishWord(name) { scores[name, default: 0] += 3 }
            }
            return true
        }

        let checker = NSSpellChecker.shared
        for raw in text.split(whereSeparator: { $0.isWhitespace || ",;:()[]{}\"“”!?".contains($0) }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".'’`"))
            // Contractions and possessives aren't terms ("It'll", or OCR's "It'Il").
            guard word.count >= 3, word.count <= 40, word.contains(where: \.isLetter), !word.contains("'"), !word.contains("’") else { continue }
            let hasInnerCaps = TermShape.isCamelCase(word)
            let isIdentifier = word.contains("_") || (codeMode && word.contains("."))
            // "gpt4o", "S3Bucket" — but not OCR debris like "o0U".
            let hasDigits = word.contains(where: \.isNumber) && word.filter(\.isLetter).count >= 3
            if hasInnerCaps || isIdentifier || hasDigits {
                scores[word, default: 0] += 2
            } else if word.first?.isUppercase == true, word.count >= 4, !CommonWords.contains(word.lowercased()) {
                // Capitalized word the spell checker doesn't know: likely a name or product. Known capitalized
                // words (names the Mac has learned, "Kubernetes") still count, ranked lower — only terms that
                // match what was said are ever used.
                // A proper noun or jargon: unknown to the spell checker, or (since the Mac's spell checker learns the
                // user's words) not an ordinary English word — "Priya", "Kubernetes" yes; "Settings" no.
                let unknown = checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound
                if unknown || !isEnglishWord(word) { scores[word, default: 0] += 2 }
            }
        }
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }
}

/// Reads the selected text: Accessibility first, then a synthetic ⌘C (restoring the clipboard) for apps
/// that don't expose their selection (Chrome, Slack, Electron apps).
@MainActor
enum SelectionReader {
    static func read() async -> String? {
        if let text = ContextReader.selectedText() { return text }
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        let before = pasteboard.changeCount
        TextInserter.postShortcut(key: TextInserter.keyCode(for: "c") ?? 8, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(180))
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects(saved.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
        return text?.isEmpty == false ? text : nil
    }
}
