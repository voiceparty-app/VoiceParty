import SwiftUI
import VoicePartyCore

/// The dictation bar: the pill at the bottom of the screen.
struct DictationBarView: View {
    @Bindable var model: DictationBarModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: phaseKey)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 10)
    }

    private var phaseKey: String {
        switch model.phase {
        case .hidden: "hidden"
        case .resting: "resting-\(model.hovering)"
        case .listening(let m): "listening-\(m.rawValue)"
        case .processing: "processing"
        case .toast(let t): "toast-\(t.id)"
        case .answer: "answer"
        case .notetaking: "notetaking"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            Color.clear.frame(width: 1, height: 1)
        case .resting:
            RestingPill(hovering: model.hovering, hotkey: model.hotkeyName, onStart: { model.onStartFromBar?() })
                .onHover { model.hovering = $0 }
                .transition(.opacity)
        case .listening(let mode):
            VStack(spacing: 8) {
                if let notice = model.notice {
                    Text(notice)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                ListeningPill(mode: mode, level: model.level, onCancel: { model.onCancel?() }, onFinish: { model.onFinish?() })
            }
            .animation(.easeOut(duration: 0.2), value: model.notice)
            .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
        case .processing(let mode):
            ProcessingPill(mode: mode)
                .transition(.opacity)
        case .toast(let toast):
            ToastPill(toast: toast) { model.hide() }
                .id(toast.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .notetaking:
            NotetakerPill(startedAt: model.notetakerStartedAt ?? Date(), onNotepad: { model.onShowNotepad?() },
                          onStop: { model.onStopNotetaker?() })
                .transition(.opacity)
        case .answer(let answer):
            AnswerCard(answer: answer,
                       onCopy: { model.onCopyAnswer?(answer.text); model.hide() },
                       onInsert: { model.onInsertAnswer?(answer.text); model.hide() },
                       onClose: { model.hide() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Pieces

private struct PillBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color.black.opacity(0.94)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }
}

extension View {
    fileprivate func pill() -> some View { modifier(PillBackground()) }
}

private struct Waveform: View {
    var level: Float
    var bars = 11
    var tint: Color = .white

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        .frame(width: 2.4, height: height(i, t))
                }
            }
            .frame(height: 20)
        }
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let quiet = level < 0.06
        if quiet { return 2.4 }
        let mid = Double(bars - 1) / 2
        let envelope = 1 - abs(Double(i) - mid) / mid * 0.55
        let wobble = 0.55 + 0.45 * sin(t * 11 + Double(i) * 1.9)
        return CGFloat(3 + Double(level) * 17 * envelope * wobble)
    }
}

private struct CircleButton: View {
    var symbol: String
    var filled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(filled ? Color.black : Color.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(filled ? Color.white : Color(white: 0.24)))
        }
        .buttonStyle(.plain)
    }
}

private struct ListeningPill: View {
    var mode: DictationMode
    var level: Float
    var onCancel: () -> Void
    var onFinish: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch mode {
            case .hold:
                Waveform(level: level)
                    .padding(.horizontal, 14)
            case .handsFree:
                CircleButton(symbol: "xmark", filled: false, action: onCancel)
                Waveform(level: level)
                CircleButton(symbol: "checkmark", filled: true, action: onFinish)
            case .command:
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.78, green: 0.66, blue: 1))
                    .padding(.leading, 4)
                Waveform(level: level, tint: Color(red: 0.86, green: 0.8, blue: 1))
                CircleButton(symbol: "checkmark", filled: true, action: onFinish)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 30)
        .pill()
    }
}

private struct ProcessingPill: View {
    var mode: DictationMode

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.35 + 0.65 * max(0, sin(t * 6 - Double(i) * 0.7))))
                        .frame(width: 3.5, height: 3.5)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 30)
        }
        .pill()
    }
}

private struct RestingPill: View {
    var hovering: Bool
    var hotkey: String
    var onStart: () -> Void

    var body: some View {
        Group {
            if hovering {
                Button(action: onStart) {
                    Text("Click or hold \(hotkey) to start dictating")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                .pill()
            } else {
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .frame(width: 44, height: 9)
                    .padding(8)
                    .contentShape(Rectangle())
            }
        }
    }
}

/// Recording a meeting: a pulsing dot, the elapsed time, and Stop.
private struct NotetakerPill: View {
    var startedAt: Date
    var onNotepad: () -> Void
    var onStop: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1, green: 0.36, blue: 0.33)).frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            Text("Notes")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.elapsed(context.date.timeIntervalSince(startedAt)))
                    .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            Button(action: onNotepad) {
                Image(systemName: "square.and.pencil").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the notepad")
            Button(action: onStop) {
                Image(systemName: "stop.fill").font(.system(size: 9)).foregroundStyle(.black)
                    .frame(width: 20, height: 20).background(Circle().fill(.white))
            }
            .buttonStyle(.plain)
            .help("Stop and write the notes")
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: 28)
        .pill()
        .onAppear { pulse = true }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct ToastPill: View {
    var toast: DictationBarModel.Toast
    var onDismiss: () -> Void
    @State private var progress: CGFloat = 1

    var body: some View {
        HStack(spacing: 12) {
            if toast.style == .error {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
            }
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            if let title = toast.actionTitle {
                Button {
                    toast.action?()
                    onDismiss()
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.26)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, toast.actionTitle == nil ? 16 : 6)
        .frame(height: 36)
        .background(Capsule().fill(Color(white: 0.09)))
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: max(0, (geo.size.width - 36) * progress), height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
            }
            .frame(height: 2)
            .padding(.bottom, 1)
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .onAppear {
            withAnimation(.linear(duration: toast.duration)) { progress = 0 }
        }
    }
}

private struct AnswerCard: View {
    var answer: DictationBarModel.Answer
    var onCopy: () -> Void
    var onInsert: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color(red: 0.78, green: 0.66, blue: 1))
                Text(answer.question).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.6)) }.buttonStyle(.plain)
            }
            // Short answers take their natural height; long ones scroll inside 180 pt.
            ViewThatFits(in: .vertical) {
                answerText.fixedSize(horizontal: false, vertical: true)
                ScrollView { answerText }
            }
            .frame(maxHeight: 180)
            HStack {
                Spacer()
                Button("Copy", action: onCopy).buttonStyle(CardButtonStyle(filled: false))
                Button("Insert", action: onInsert).buttonStyle(CardButtonStyle(filled: true))
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var answerText: some View {
        Text(answer.text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CardButtonStyle: ButtonStyle {
    var filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(filled ? Color.white : Color(white: 0.24)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
