import Foundation

/// Recording a conversation can need everyone's consent (the law differs by place), so the Notetaker explains
/// that once, offers a message to paste into the call's chat, and hears only the call when it knows the call.
public enum NotetakerConsent {
    /// Shown the first time the Notetaker starts on this Mac.
    public static let explanation = """
        The Notetaker records your microphone and what the other people say, transcribes it and writes notes — all on \
        this Mac. In many places everyone in a conversation has to agree to it being recorded. Tell the others you're \
        taking notes before you start; VoiceParty can copy a message for the chat.
        """

    /// Copied for the call's chat.
    public static let message = "Heads up: I'm taking notes of this call with an app that transcribes it on my Mac. Let me know if you'd rather I didn't."

    /// Which audio processes to record for the others' side: only the call app's when the Notetaker was started for a
    /// detected call (not music, other tabs or notifications); nil = everything the Mac plays (started by hand, or
    /// the call app's audio process wasn't found).
    public static func tapProcesses(callApp: String?, among processes: [(bundleID: String, id: UInt32)]) -> [UInt32]? {
        guard let callApp else { return nil }
        let ids = processes.filter { CallDetector.appName(forBundleID: $0.bundleID) == callApp }.map(\.id)
        return ids.isEmpty ? nil : ids
    }
}
