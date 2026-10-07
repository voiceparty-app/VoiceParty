#if VOICEPARTY_DEBUG_URLS
import AppKit
import ApplicationServices

/// Debug (voiceparty://debug/ax-probe?bundles=a,b): how each running app exposes its focused text field to
/// Accessibility — roles, attribute names, whether its text is readable, how long it is and how it's shaped
/// (newlines, non-breaking spaces). Structure only: no text is written. → debug-ax.json
enum AXProbe {
    /// `wake`: first read each app's role, as a dictation's key-down now does (Chromium apps switch their accessibility on), and
    /// give them two seconds.
    static func report(bundles: [String], wake: Bool = false) -> [String: Any] {
        if wake {
            for bundle in bundles {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXRoleAttribute as CFString, &role)
            }
            Thread.sleep(forTimeInterval: 2)
        }
        var out: [String: Any] = [:]
        for bundle in bundles {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
                out[bundle] = ["running": false]
                continue
            }
            out[bundle] = probe(pid: app.processIdentifier, active: app.isActive)
        }
        return out
    }

    static func probe(pid: pid_t, active: Bool) -> [String: Any] {
        var r: [String: Any] = ["running": true, "frontmost": active]
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1)
        // What ContextReader.snapshot does at every dictation.
        r["setManualAccessibility"] = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
        r["appAttributes"] = names(appElement)
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        r["focusedError"] = error.rawValue
        guard error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            r["tree"] = walk(appElement)
            return r
        }
        let element = focused as! AXUIElement
        r["role"] = string(element, kAXRoleAttribute)
        r["subrole"] = string(element, kAXSubroleAttribute)
        r["roleDescription"] = string(element, kAXRoleDescriptionAttribute)
        r["attributes"] = names(element)
        var parameterized: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &parameterized) == .success {
            r["parameterizedAttributes"] = parameterized as? [String]
        }
        r["domClasses"] = copy(element, "AXDOMClassList") as? [String]
        var value: CFTypeRef?
        let started = Date()
        let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        r["valueReadMs"] = Int(Date().timeIntervalSince(started) * 1000)
        r["valueError"] = valueError.rawValue
        if let value {
            r["valueType"] = CFCopyTypeIDDescription(CFGetTypeID(value)) as String
            if let text = value as? String {
                r["value"] = shape(text)
                if let placeholder = copy(element, "AXPlaceholderValue") as? String { r["valueIsPlaceholder"] = !text.isEmpty && text == placeholder }
                // The same text through the range API (some editors expose only that).
                if let count = copy(element, kAXNumberOfCharactersAttribute) as? Int {
                    r["numberOfCharacters"] = count
                    var range = CFRange(location: 0, length: count)
                    if let rangeValue = AXValueCreate(.cfRange, &range) {
                        var ranged: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &ranged) == .success,
                           let ranged = ranged as? String {
                            r["stringForRangeEqualsValue"] = ranged == text
                        }
                    }
                }
            }
        }
        r["selectedRangeReadable"] = copy(element, kAXSelectedTextRangeAttribute) != nil
        // The watcher's focus check compares the focused element read again later with the one kept at key-down.
        var again: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &again) == .success, let again {
            r["sameElementOnReread"] = CFEqual(again, element)
        }
        var systemFocused: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &systemFocused) == .success,
           let systemFocused {
            r["systemWideFocusedIsThisElement"] = CFEqual(systemFocused, element)
        }
        var chain: [String] = []
        var current = copy(element, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        for _ in 0..<10 {
            guard let node = current else { break }
            let classes = (copy(node, "AXDOMClassList") as? [String]).map { " ." + $0.prefix(4).joined(separator: ".") } ?? ""
            chain.append((string(node, kAXRoleAttribute) ?? "?") + "/" + (string(node, kAXSubroleAttribute) ?? "-") + classes)
            current = copy(node, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        r["parents"] = chain
        r["tree"] = walk(appElement)
        return r
    }

    /// The app's whole tree, summarized: how many nodes of each role, and every text field with whether it says it
    /// has focus (Chromium can report the page as focused while a field inside it is).
    static func walk(_ appElement: AXUIElement) -> [String: Any] {
        var roles: [String: Int] = [:]
        var fields: [[String: Any]] = []
        var visited = 0
        var stack: [(AXUIElement, Int)] = [(appElement, 0)]
        let started = Date()
        while let (node, depth) = stack.popLast(), visited < 4000, Date().timeIntervalSince(started) < 4 {
            visited += 1
            let role = string(node, kAXRoleAttribute) ?? "?"
            roles[role, default: 0] += 1
            if ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role) {
                var field: [String: Any] = ["role": role, "depth": depth]
                field["subrole"] = string(node, kAXSubroleAttribute)
                field["focused"] = copy(node, kAXFocusedAttribute) as? Bool
                field["domClasses"] = (copy(node, "AXDOMClassList") as? [String]).map { Array($0.prefix(6)) }
                if let text = copy(node, kAXValueAttribute) as? String { field["value"] = shape(text) } else { field["valueReadable"] = false }
                if let placeholder = copy(node, "AXPlaceholderValue") as? String { field["hasPlaceholder"] = !placeholder.isEmpty }
                fields.append(field)
            }
            guard depth < 60, let children = copy(node, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children.reversed() { stack.append((child, depth + 1)) }
        }
        return ["nodes": visited, "roles": roles, "textFields": fields, "ms": Int(Date().timeIntervalSince(started) * 1000),
                "enhancedUserInterface": copy(appElement, "AXEnhancedUserInterface") as? Bool as Any]
    }

    /// Counts that describe a text's shape without its content.
    static func shape(_ text: String) -> [String: Any] {
        let scalars = text.unicodeScalars
        func count(_ c: Unicode.Scalar) -> Int { scalars.filter { $0 == c }.count }
        return [
            "length": text.count, "newlines": count("\n"), "doubleNewlines": text.components(separatedBy: "\n\n").count - 1,
            "carriageReturns": count("\r"), "nbsp": count("\u{00A0}"), "lineSeparators": count("\u{2028}") + count("\u{2029}"),
            "objectReplacement": count("\u{FFFC}"), "zeroWidth": count("\u{200B}") + count("\u{FEFF}"),
            "endsWithNewline": text.hasSuffix("\n"), "words": text.split(whereSeparator: \.isWhitespace).count,
        ]
    }

    private static func names(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }
}
#endif
