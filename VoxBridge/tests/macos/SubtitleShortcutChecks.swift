import AppKit
import Carbon

@main struct SubtitleShortcutChecks {
    @MainActor static func main() throws {
        // Read Apple's installed French layout without changing the user's input source.
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: "com.apple.keylayout.French"] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        let french = sources.first!
        let raw = TISGetInputSourceProperty(french, kTISPropertyUnicodeKeyLayoutData)!
        let frenchData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        assert(SubtitleShortcutPreferences.keyName(for: 0, layoutData: frenchData) == "Q", "AZERTY key labels must describe the registered physical key")
        assert(SubtitleShortcutPreferences.keyName(for: 12, layoutData: frenchData) == "A")
        let defaults = UserDefaults(suiteName: "VoxHalo.Shortcuts.Test.\(UUID().uuidString)")!
        var shortcuts = SubtitleShortcutPreferences()
        assert(shortcuts.key(for: .toggle) == 1 && shortcuts.key(for: .up) == 126)
        assert(shortcuts.key(for: .down) == 125 && shortcuts.key(for: .top) == 25 && shortcuts.key(for: .bottom) == 29)
        assert(shortcuts.assign(126, to: .toggle) == false, "duplicate bindings must be rejected")
        assert(shortcuts.assign(20, to: .toggle) == false, "macOS clipboard screenshot keys must be rejected")
        assert(shortcuts.assign(17, to: .toggle) == false, "Finder add-to-Dock shortcut must be rejected")
        assert(shortcuts.assign(0, to: .toggle))
        shortcuts.enabled = false
        try shortcuts.save(to: defaults)
        assert(SubtitleShortcutPreferences.load(from: defaults) == shortcuts)
        defaults.set(Data("{\"enabled\":true,\"keys\":{\"toggle\":126,\"up\":126}}".utf8), forKey: SubtitleShortcutPreferences.storageKey)
        assert(Set(SubtitleShortcutAction.allCases.map { SubtitleShortcutPreferences.load(from: defaults).key(for: $0) }).count == 5,
               "corrupted or partially migrated preferences cannot register duplicate keys")

        var style = SubtitlePreferences(); style.verticalPosition = 0.5
        let shiftedScreen = CGRect(x: -1920, y: -1080, width: 1920, height: 1000)
        let before = SubtitlePreferences.frame(in: shiftedScreen, size: CGSize(width: 800, height: 200), horizontal: 0.5, vertical: 0.5)
        let raised = style.adjusted(for: .up, screenHeight: 1000, captionHeight: 200)
        let after = SubtitlePreferences.frame(in: shiftedScreen, size: before.size, horizontal: 0.5, vertical: raised.verticalPosition)
        assert(abs(after.minY - before.minY - 8) < 0.0001, "up must move exactly 8 logical points on external screens")
        assert(raised.adjusted(for: .down, screenHeight: 1000, captionHeight: 200) == style)
        let bottom = style.adjusted(for: .bottom, screenHeight: 1000, captionHeight: 200)
        assert(bottom.verticalPosition == 1 && bottom.adjusted(for: .down, screenHeight: 1000, captionHeight: 200) == bottom)
        assert(SubtitlePreferences.frame(in: shiftedScreen, size: before.size, horizontal: 0.5, vertical: bottom.verticalPosition).minY == -1080)
        let top = style.adjusted(for: .top, screenHeight: 1000, captionHeight: 200)
        assert(top.verticalPosition == 0 && top.adjusted(for: .up, screenHeight: 1000, captionHeight: 200) == top)
        assert(style.adjusted(for: .up, screenHeight: 200, captionHeight: 200) == style, "no travel space must not divide by zero")
        assert(style.adjusted(for: .up, screenHeight: .nan, captionHeight: 200) == style)
        assert(style.adjusted(for: .toggle, screenHeight: 1000, captionHeight: 200).enabled == false)

        var gesture = SubtitleShortcutGesture()
        assert(gesture.press(.toggle, at: 0) == .toggle)
        assert(gesture.press(.toggle, at: 0.1) == nil, "auto-repeat must not flicker subtitle visibility")
        assert(gesture.repeatAction(at: 1, stillHeld: true) == nil)
        gesture.release(.toggle)
        assert(gesture.press(.toggle, at: 1.1) == .toggle)
        assert(gesture.press(.up, at: 2) == .up)
        assert(gesture.repeatAction(at: 2.2, stillHeld: true) == nil)
        assert(gesture.repeatAction(at: 2.31, stillHeld: true) == .up)
        assert(gesture.repeatAction(at: 2.32, stillHeld: true) == nil)
        assert(gesture.repeatAction(at: 2.36, stillHeld: true) == .up)
        assert(gesture.repeatAction(at: 2.5, stillHeld: false) == nil, "lost key-up or released modifiers must stop motion")
        assert(gesture.repeatAction(at: 3, stillHeld: true) == nil)
        assert(gesture.press(.down, at: 4) == .down)
        gesture.reset()
        assert(gesture.repeatAction(at: 5, stillHeld: true) == nil, "stopping interpretation must cancel a held shortcut")
        print("PASS: shortcut persistence, conflicts, screen geometry, repeat and release safety")
    }
}
