import AppKit
import ScreenCaptureKit
import Vision

/// Optional screen reading (Settings → Data and Privacy, off by default): the window you're dictating into
/// is captured once and its text recognized on-device, so names visible on screen are spelled right.
/// The image and text stay in memory for that one dictation; nothing is saved or sent anywhere.
enum ScreenOCR {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows macOS's Screen Recording prompt (first time), or returns the current answer.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Text in the front window of the app with `pid`; nil without permission or on failure.
    static func text(inFrontWindowOf pid: pid_t) async -> String? {
        guard hasPermission,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              // Windows come front to back; the app's first normal-level, reasonably sized one is the one in use.
              let window = content.windows.first(where: {
                  $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 120
              }) else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(2, 2400 / max(window.frame.width, 1)) // sharp enough to read, capped for speed
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                      configuration: configuration) else { return nil }
        return await recognizeText(in: image)
    }

    /// On-device text recognition. Accurate mode: it runs while you speak, and fast mode misreads names.
    static func recognizeText(in image: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }
}
