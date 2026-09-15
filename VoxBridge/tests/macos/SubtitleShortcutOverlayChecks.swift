import AppKit
import AVFoundation

@main struct SubtitleShortcutOverlayChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let overlay = SubtitleOverlayController()
        let identity = CompletedSubtitleState.Identity(sentenceID: "one", revision: 1)
        overlay.setLiveText("Current spoken sentence.", identity: identity, synchronized: true, active: true)
        let keyWindow = NSApp.keyWindow
        let player = NativeSpeechPlayer()
        try player.start(outputUID: "default", epoch: "shortcut-check", cursor: 0)
        defer { player.stop(); overlay.close() }
        let data = Data(repeating: 0, count: 24000 * 2 * 3)
        let packet: [String: Any] = ["epoch": "shortcut-check", "cursor": 1, "chunks": [[
            "seq": 1, "sentence_id": "one", "revision": 1, "source_order": 0, "index": 0, "count": 1,
            "sample_rate": 24000, "pcm": data.base64EncodedString(), "duration_ms": 3000,
            "text": "Current spoken sentence.", "created_at_ms": 1]]]
        try player.accept(JSONDecoder().decode(NativeSpeechSnapshot.self, from: JSONSerialization.data(withJSONObject: packet)))
        let before = player.bufferedMilliseconds
        let startY = overlay.panel.frame.minY
        overlay.apply(preferences: overlay.adjustedPreferences(for: .up))
        assert(abs(overlay.panel.frame.minY - startY - 8) < 0.001)
        overlay.apply(preferences: overlay.adjustedPreferences(for: .toggle))
        assert(!overlay.panel.isVisible)
        overlay.setLiveText("Next currently spoken sentence.", identity: .init(sentenceID: "two", revision: 1), synchronized: true, active: true)
        overlay.apply(preferences: overlay.adjustedPreferences(for: .bottom))
        assert(!overlay.panel.isVisible, "moving a hidden caption must not reveal it")
        overlay.apply(preferences: overlay.adjustedPreferences(for: .toggle))
        assert(overlay.textView.accessibilityValue() as? String == "Next currently spoken sentence.", "show must use the current playback caption")
        assert(overlay.panel.frame.minY == NSScreen.screens[0].frame.minY)
        for index in 0..<30 {
            overlay.apply(preferences: overlay.adjustedPreferences(for: index % 2 == 0 ? .up : .down))
            if index % 5 == 0 { overlay.apply(preferences: overlay.adjustedPreferences(for: .toggle)) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        assert(player.isPlaying && player.bufferedMilliseconds < before - 400,
               "real output must keep advancing during rapid subtitle changes")
        assert(NSApp.keyWindow === keyWindow, "subtitle changes must not take keyboard focus")
        try await Task.sleep(nanoseconds: 2_600_000_000)
        assert(player.playedSequence == 1 && player.drained, "the original PCM must drain without rescheduling or restarting")
        print("PASS: current-caption restore, hidden positioning, unchanged focus and continuous PCM playback")
    }
}
