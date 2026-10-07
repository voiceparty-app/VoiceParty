#if VOICEPARTY_DEBUG_URLS
import AppKit
import ApplicationServices
import VoicePartyCore
import WebKit

/// Debug: how each edit watch ended, without any text (debug-edit-watch.json, the last 30): the app, the role of the
/// field, the outcome and why nothing was learned. Only with the DebugURLs default on.
@MainActor
enum EditWatchLog {
    static func append(_ result: EditWatchRun.Result, app: String?, learned: EditDiffLearner.Learned?, dry: Bool) {
        let url = Paths.appSupport.appending(path: "debug-edit-watch.json")
        var entries = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        var entry: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "app": app ?? "?", "role": result.role ?? "?",
                                    "seconds": (result.seconds * 10).rounded() / 10, "reads": result.reads, "changeNotifications": result.nudges,
                                    "dry": dry]
        switch result.outcome {
        case .corrected: entry["outcome"] = "corrected"
        case .unchanged: entry["outcome"] = "unchanged"
        case .notFound(let reason): entry["outcome"] = "notFound:\(reason.rawValue)"
        }
        if let learned {
            entry["learnedWords"] = learned.words.count
            entry["learnedReplacements"] = learned.replacements.count
        }
        entries.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: Array(entries.suffix(30)), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

/// Debug (voiceparty://debug/edit-test): the edit watcher end to end on a field in VoiceParty's own invisible window —
/// an AppKit text view (`field=text`, like TextEdit or Notes) or a web editor shaped like ProseMirror (`field=web`, like
/// the Claude and ChatGPT composers) — read through Accessibility like any app's. The field gets `prefix` + `pasted`
/// as if it had just been dictated, then the `steps` run (`|`-separated): `wait:SECONDS`, `replace:OLD=NEW[@MS]` (NEW
/// typed a character every MS milliseconds), `send` (the box empties, as Enter does in a chat app), `rewrite:TEXT`, `cancel`
/// (what the next dictation does to a running watch).
/// Nothing is learned: what would be is written to debug-edit-test.json, using `dictionary` (comma-separated words)
/// instead of the user's. Never touches another app.
@MainActor
enum DebugEditTest {
    nonisolated static let title = "VoiceParty edit test"
    private static var window: NSWindow?

    enum Step {
        case wait(Double)
        case replace(String, String, perCharacter: Double)
        case send
        case cancel
        case rewrite(String)

        static func parse(_ text: String) -> [Step] {
            text.split(separator: "|").compactMap { raw in
                let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts.first {
                case "wait": return .wait(Double(parts.last ?? "") ?? 1)
                case "send": return .send
                case "cancel": return .cancel
                case "rewrite": return parts.count == 2 ? .rewrite(parts[1]) : nil
                case "replace":
                    guard parts.count == 2 else { return nil }
                    var body = parts[1], ms = 0.0
                    if let at = body.lastIndex(of: "@"), let value = Double(body[body.index(after: at)...]) {
                        ms = value
                        body = String(body[..<at])
                    }
                    let pair = body.split(separator: "=", maxSplits: 1).map(String.init)
                    return pair.count == 2 ? .replace(pair[0], pair[1], perCharacter: ms / 1000) : nil
                default: return nil
                }
            }
        }
    }

    /// The field: what it shows, and how the steps change it.
    protocol Field: AnyObject {
        @MainActor func load(_ text: String) async
        @MainActor func replace(_ old: String, with new: String, perCharacter: Double) async
        @MainActor func empty() async
        @MainActor func rewrite(_ text: String) async
    }

    static func run(app: AppModel, kind: String, prefix: String, pasted: String, steps: [Step], dictionary: [DictionaryEntry],
                    window watchWindow: TimeInterval = 60) async -> [String: Any] {
        window?.close()
        let frame = NSRect(x: (NSScreen.main?.frame.minX ?? 0) + 8, y: (NSScreen.main?.frame.minY ?? 0) + 8, width: 420, height: 180)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.alphaValue = 0 // invisible and click-through: it only has to exist for Accessibility
        window.ignoresMouseEvents = true
        Self.window = window
        let field: Field = kind == "web" ? WebField(in: window) : TextField(in: window)
        window.orderFrontRegardless()
        await field.load(prefix + pasted)

        var report: [String: Any] = ["field": kind, "pasted": pasted, "prefix": prefix]
        guard let element = await Task.detached(operation: { Self.findField() }).value else {
            report["error"] = "the test field isn't visible to Accessibility"
            window.close()
            return report
        }
        let reader = FieldReader(.element(element))
        report["fieldShape"] = await Task.detached { () -> [String: Any]? in
            if case .text(let value) = reader.read() { return AXProbe.shape(value) }
            return nil
        }.value
        var config = EditWatch()
        config.window = watchWindow
        let watch = Task.detached { [config] in await EditWatchRun.run(reader, pasted: pasted, watch: config) }
        try? await Task.sleep(for: .milliseconds(800))
        for step in steps {
            switch step {
            case .wait(let seconds): try? await Task.sleep(for: .seconds(seconds))
            case .replace(let old, let new, let perCharacter): await field.replace(old, with: new, perCharacter: perCharacter)
            case .send: await field.empty()
            case .cancel: watch.cancel()
            case .rewrite(let text): await field.rewrite(text)
            }
        }
        let result = await watch.value
        window.close()

        report["role"] = result.role ?? "?"
        report["reads"] = result.reads
        report["changeNotifications"] = result.nudges
        report["seconds"] = (result.seconds * 100).rounded() / 100
        switch result.outcome {
        case .corrected(let original, let edited):
            report["outcome"] = "corrected"
            report["edited"] = edited
            let learned = app.plannedLearning(pasted: original, edited: edited, dictionary: dictionary)
            report["learnedWords"] = learned.words
            report["learnedReplacements"] = learned.replacements.map { "\($0.from) → \($0.to)" }
        case .unchanged: report["outcome"] = "unchanged"
        case .notFound(let reason): report["outcome"] = "notFound:\(reason.rawValue)"
        }
        return report
    }

    /// The test window's editable element, through Accessibility like any other app's (off the main thread: the main
    /// thread answers these requests).
    nonisolated static func findField() -> AXUIElement? {
        let app = AXUIElementCreateApplication(getpid())
        for _ in 0..<40 {
            let windows: [AXUIElement] = FieldReader.copy(app, kAXWindowsAttribute) ?? []
            for window in windows where (FieldReader.copy(window, kAXTitleAttribute) as String?) == title {
                var stack = [window]
                var visited = 0
                while let node = stack.popLast(), visited < 400 {
                    visited += 1
                    if let role: String = FieldReader.copy(node, kAXRoleAttribute), ["AXTextArea", "AXTextField"].contains(role) { return node }
                    stack.append(contentsOf: (FieldReader.copy(node, kAXChildrenAttribute) as [AXUIElement]?) ?? [])
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// An AppKit text view.
    @MainActor final class TextField: Field {
        let view: NSTextView

        init(in window: NSWindow) {
            let scroll = NSTextView.scrollableTextView()
            view = scroll.documentView as! NSTextView
            view.isRichText = false
            window.contentView = scroll
            window.makeFirstResponder(view)
        }

        func load(_ text: String) async { view.string = text }

        func replace(_ old: String, with new: String, perCharacter: Double) async {
            let range = (view.string as NSString).range(of: old, options: .backwards)
            guard range.location != NSNotFound else { return }
            view.insertText("", replacementRange: range)
            var location = range.location // the window is never key, so the selection doesn't follow the typing
            for character in new {
                view.insertText(String(character), replacementRange: NSRange(location: location, length: 0))
                location += (String(character) as NSString).length
                if perCharacter > 0 { try? await Task.sleep(for: .seconds(perCharacter)) }
            }
        }

        func empty() async {
            view.insertText("", replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        }

        func rewrite(_ text: String) async {
            view.insertText(text, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        }
    }

    /// A contenteditable shaped like ProseMirror: one <p> per paragraph, an empty box is an empty paragraph; edits go
    /// through the browser's own editing commands, as typing does.
    @MainActor final class WebField: NSObject, Field, WKNavigationDelegate {
        let view = WKWebView()
        private var loaded: CheckedContinuation<Void, Never>?

        init(in window: NSWindow) {
            super.init()
            view.navigationDelegate = self
            window.contentView = view
        }

        func load(_ text: String) async {
            let paragraphs = text.components(separatedBy: "\n").filter { !$0.isEmpty }.map { "<p>\(Self.escape($0))</p>" }.joined()
            let html = """
            <html><body><div id="ed" class="ProseMirror" contenteditable="true">\(paragraphs)</div><script>
            function replaceLast(old) {
              const ed = document.getElementById('ed'); const walker = document.createTreeWalker(ed, NodeFilter.SHOW_TEXT);
              let hit = null, node; while ((node = walker.nextNode())) { const i = node.data.lastIndexOf(old); if (i >= 0) hit = [node, i]; }
              if (!hit) return false; const r = document.createRange(); r.setStart(hit[0], hit[1]); r.setEnd(hit[0], hit[1] + old.length);
              const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); document.execCommand('delete'); return true;
            }
            </script></body></html>
            """
            await withCheckedContinuation { continuation in
                loaded = continuation
                view.loadHTMLString(html, baseURL: nil)
            }
            _ = try? await view.evaluateJavaScript("document.getElementById('ed').focus(); true")
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                loaded?.resume()
                loaded = nil
            }
        }

        func replace(_ old: String, with new: String, perCharacter: Double) async {
            guard (try? await view.evaluateJavaScript("replaceLast(\(Self.jsString(old)))")) as? Bool == true else { return }
            for character in new {
                _ = try? await view.evaluateJavaScript("document.execCommand('insertText', false, \(Self.jsString(String(character)))); true")
                if perCharacter > 0 { try? await Task.sleep(for: .seconds(perCharacter)) }
            }
        }

        func empty() async {
            _ = try? await view.evaluateJavaScript("document.getElementById('ed').innerHTML = '<p><br></p>'; true")
        }

        func rewrite(_ text: String) async {
            _ = try? await view.evaluateJavaScript("document.getElementById('ed').innerHTML = '<p>' + \(Self.jsString(text)) + '</p>'; true")
        }

        static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }

        static func jsString(_ text: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
    }
}
#endif
