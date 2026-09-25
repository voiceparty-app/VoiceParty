import SwiftUI
import VoicePartyCore

struct EnhancementsView: View {
    @Bindable var app: AppModel

    private var cards: [Enhancement] { EnhancementCatalog.all.filter { !$0.isSupport } }
    private var memory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Enhancements", subtitle: "Optional upgrades you can download. Everything still runs on this Mac.")

                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "wand.and.stars").font(.system(size: 22)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cleaning up with: \(cleanupSummary)").font(.system(size: 14, weight: .semibold))
                            Text("VoiceParty works without any enhancements, using Apple Intelligence (when it's on) or its built-in rules.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(cards) { enhancement in
                    EnhancementCard(app: app, enhancement: enhancement, memory: memory)
                }

                Label {
                    Text("Downloads come from GitHub (llama.cpp) and Hugging Face, pinned to exact versions and checked by fingerprint (SHA-256) when installed and again before each use. The models run on this Mac and only VoiceParty can talk to them; VoiceParty doesn't upload what you say.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                }
            }
            .hubPageLayout()
        }
    }

    private var cleanupSummary: String { app.cleanupSummary }
}

private struct EnhancementCard: View {
    @Bindable var app: AppModel
    let enhancement: Enhancement
    let memory: UInt64

    private var state: EnhancementManager.State { app.enhancements.state(enhancement.id) }
    private var totalBytes: Int64 {
        let installed = Set(EnhancementCatalog.all.map(\.id).filter(app.enhancements.isInstalled))
        return EnhancementCatalog.downloadBytes(for: enhancement.id, installed: installed)
    }

    @ViewBuilder private func licenseLink(_ enhancement: Enhancement) -> some View {
        if let name = enhancement.licenseName, let url = enhancement.licenseURL {
            Link("(\(name))", destination: url).foregroundStyle(Theme.accent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(enhancement.name).font(Theme.display(22))
                Spacer()
                if state == .installed {
                    Label("Installed", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            Text(enhancement.summary).font(.system(size: 14, weight: .medium))
            Text(enhancement.details).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(([ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) + (state == .installed ? " on disk" : " download")]
                      + [enhancement.credit].compactMap { $0 }).joined(separator: "  ·  "))
                licenseLink(enhancement)
                // Models that run on the local AI engine: credit it too.
                if enhancement.requires.contains(EnhancementID.localRuntime), let runtime = EnhancementCatalog.enhancement(EnhancementID.localRuntime) {
                    Text("·  runs on \(runtime.credit ?? "llama.cpp")")
                    licenseLink(runtime)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if enhancement.recommendedMemory > 0 && memory < enhancement.recommendedMemory {
                Label("Recommended for Macs with \(enhancement.recommendedMemory >> 30) GB of memory or more; this Mac has \(memory >> 30) GB.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Theme.highlight)
            }
            controls
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(state == .installed ? Theme.accent.opacity(0.4) : Theme.hairline))
    }

    @ViewBuilder private var controls: some View {
        switch state {
        case .notInstalled:
            Button("Download") { app.enhancements.install(enhancement.id) }.buttonStyle(PrimaryButtonStyle())
        case .downloading(let progress, let detail):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.accent)
                HStack {
                    Text("Downloading \(detail)… \(Int(progress * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { app.enhancements.cancel(enhancement.id) }.buttonStyle(.plain).font(.system(size: 12))
                }
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying and installing…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .installed:
            Button("Remove") { app.enhancements.remove(enhancement.id) }.buttonStyle(SecondaryButtonStyle())
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon").font(.system(size: 12)).foregroundStyle(.red)
                Button("Try again") { app.enhancements.install(enhancement.id) }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
