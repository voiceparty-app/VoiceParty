import AppKit
import SwiftUI

/// Warm off-white canvas, white cards, serif display type —
/// with a matching dark appearance.
enum Theme {
    static let canvas = dynamic(light: NSColor(red: 0.957, green: 0.949, blue: 0.933, alpha: 1),
                                dark: NSColor(red: 0.118, green: 0.114, blue: 0.106, alpha: 1))
    static let card = dynamic(light: NSColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1),
                              dark: NSColor(red: 0.153, green: 0.149, blue: 0.141, alpha: 1))
    static let well = dynamic(light: NSColor(red: 0.953, green: 0.945, blue: 0.929, alpha: 1),
                              dark: NSColor(red: 0.2, green: 0.196, blue: 0.188, alpha: 1))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))
    static let selection = dynamic(light: NSColor(red: 0.91, green: 0.9, blue: 0.88, alpha: 1),
                                   dark: NSColor(white: 1, alpha: 0.08))
    static let accent = dynamic(light: NSColor(red: 0.184, green: 0.412, blue: 0.396, alpha: 1),
                                dark: NSColor(red: 0.42, green: 0.72, blue: 0.69, alpha: 1))
    static let accentSoft = dynamic(light: NSColor(red: 0.184, green: 0.412, blue: 0.396, alpha: 0.12),
                                    dark: NSColor(red: 0.42, green: 0.72, blue: 0.69, alpha: 0.16))
    static let highlight = Color(red: 0.95, green: 0.66, blue: 0.3)
    static let sparkle = Color(red: 0.62, green: 0.48, blue: 0.95)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// Every hub page's content column: the same margins and width on every page.
    func hubPageLayout() -> some View {
        padding(36)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
            .background(OverlayScrollers())
    }
}

/// Switches the enclosing scroll view to overlay scroll bars. With a mouse connected, macOS otherwise
/// reserves a scroll-bar gutter on pages long enough to scroll, so their right edge sits ~16 pt left of
/// short pages and the layout jumps when you switch pages.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard observer == nil else { return }
            // AppKit resets the style when the system preference changes; re-apply after it does.
            observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.apply() }
            }
        }

        private func apply() {
            enclosingScrollView?.scrollerStyle = .overlay
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    /// Stretch to the row's height (cards side by side share top and bottom edges).
    var fillsHeight = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
    }
}

/// A grouped settings box: rows separated by hairlines.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))
    }
}

struct SettingsRow<Accessory: View>: View {
    var title: String
    var detail: String?
    var showDivider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            if showDivider { Divider().padding(.horizontal, 16).opacity(0.6) }
        }
    }
}

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.display(30))
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Key-cap chip used for shortcuts ("fn", "⌃ Ctrl").
struct KeyCap: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 120, idealWidth: 220, maxWidth: 220, minHeight: 30, maxHeight: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
    }
}
