import AppKit
import Carbon.HIToolbox
import Foundation

/// Turns the end of a voice session into a submitted prompt for the agent app.
///
/// The speech-to-text step is delegated to the user's dictation input method
/// (豆包输入法 or any other tool listening on the loopback device). This class only
/// does the last mile: make sure the agent app is frontmost, wait for the dictated
/// text to settle, then press Return.
@MainActor
final class VoiceAgentSubmitter {
    static let shared = VoiceAgentSubmitter()

    private enum Key {
        static let isEnabled = "computerControl.voiceSubmit.isEnabled"
        static let targetBundleID = "computerControl.voiceSubmit.targetBundleID"
        static let settleDelay = "computerControl.voiceSubmit.settleDelay"
    }

    private let defaults: UserDefaults
    private var releaseWorkItem: DispatchWorkItem?

    private(set) var isEnabled: Bool
    private(set) var targetBundleID: String
    private(set) var settleDelay: Double

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        targetBundleID = defaults.string(forKey: Key.targetBundleID) ?? ""
        let storedDelay = defaults.object(forKey: Key.settleDelay) as? Double
        settleDelay = storedDelay ?? 1.0
    }

    func update(isEnabled: Bool? = nil, targetBundleID: String? = nil, settleDelay: Double? = nil) {
        if let isEnabled {
            self.isEnabled = isEnabled
            defaults.set(isEnabled, forKey: Key.isEnabled)
        }
        if let targetBundleID {
            self.targetBundleID = targetBundleID
            defaults.set(targetBundleID, forKey: Key.targetBundleID)
        }
        if let settleDelay {
            self.settleDelay = settleDelay.clamped(to: 0.2...4)
            defaults.set(self.settleDelay, forKey: Key.settleDelay)
        }
    }

    /// Candidate agent apps: anything installed that commonly hosts a coding agent,
    /// plus whatever the user already selected.
    func candidateApplications() -> [(bundleID: String, name: String)] {
        let known = [
            "com.anthropic.claudefordesktop",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty",
            "com.openai.codex",
            "ai.opencode.desktop",
            "com.todesktop.230313mzl4w4u92",
        ]
        var seen = Set<String>()
        var result: [(String, String)] = []
        for bundleID in known {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            if seen.insert(bundleID).inserted {
                result.append((bundleID, name))
            }
        }
        if !targetBundleID.isEmpty, !seen.contains(targetBundleID) {
            result.insert((targetBundleID, targetBundleID), at: 0)
        }
        return result
    }

    /// Called when the voice stream ends. Idempotent per session.
    func handleVoiceSessionEnded() {
        guard isEnabled, !targetBundleID.isEmpty else { return }
        releaseWorkItem?.cancel()
        let bundleID = targetBundleID
        let delay = settleDelay
        let work = DispatchWorkItem { [weak self] in
            self?.activateAndSubmit(bundleID: bundleID)
        }
        releaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func activateAndSubmit(bundleID: String) {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
        else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                try? NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
            AppLogger.shared.write("[voice-agent] target app not running: \(bundleID)")
            return
        }
        application.activate(options: [.activateAllWindows])
        // Give the app a beat to take focus before the synthetic Return, otherwise
        // the keystroke lands in the previous app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            Self.postReturn()
            AppLogger.shared.write("[voice-agent] submitted prompt to \(bundleID)")
        }
    }

    private static func postReturn() {
        guard AXIsProcessTrusted() else {
            AppLogger.shared.write("[voice-agent] accessibility permission missing; cannot submit")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Return),
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Return),
            keyDown: false
        ) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
