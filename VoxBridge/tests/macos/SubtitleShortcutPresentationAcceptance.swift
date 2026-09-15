import AppKit

/// Manual acceptance harness: run while PowerPoint presents a disposable deck,
/// then press the documented keys. No audio capture, model service or saved
/// preference is touched. stdout records actual OS-delivered hotkey actions.
@main struct SubtitleShortcutPresentationAcceptance {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let overlay = SubtitleOverlayController(), hotkeys = SubtitleHotKeyController()
        var style = SubtitlePreferences(), sequence = 1
        let began = ProcessInfo.processInfo.systemUptime
        overlay.apply(preferences: style)
        overlay.setLiveText("VoxHalo · Subtitle shortcut test 1", identity: .init(sentenceID: "1", revision: 1), synchronized: true, active: true)
        hotkeys.configure(SubtitleShortcutPreferences())
        hotkeys.onAction = { action in
            let previous = overlay.panel.frame.minY
            style = overlay.adjustedPreferences(for: action); overlay.apply(preferences: style)
            let record: [String: Any] = ["action": action.rawValue, "seconds": ProcessInfo.processInfo.systemUptime - began,
                "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "visible": overlay.panel.isVisible,
                "previous_y": previous, "y": overlay.panel.frame.minY, "vertical": style.verticalPosition,
                "text": overlay.textView.accessibilityValue() as? String ?? ""]
            print(String(data: try! JSONSerialization.data(withJSONObject: record, options: .sortedKeys), encoding: .utf8)!); fflush(stdout)
        }
        hotkeys.setActive(true)
        print("READY: \(hotkeys.registeredActions.count) shortcuts; failures \(hotkeys.failures)"); fflush(stdout)
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                sequence += 1
                overlay.setLiveText("VoxHalo · Subtitle shortcut test \(sequence)", identity: .init(sentenceID: String(sequence), revision: 1), synchronized: true, active: true)
            }
        }
        let duration = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 180
        Timer.scheduledTimer(withTimeInterval: min(600, max(10, duration)), repeats: false) { _ in
            MainActor.assumeIsolated { hotkeys.setActive(false); overlay.close(); app.terminate(nil) }
        }
        app.run()
    }
}
