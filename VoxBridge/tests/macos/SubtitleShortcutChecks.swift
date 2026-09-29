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
        for (key, label) in [(UInt32(123), "←"), (124, "→"), (125, "↓"), (126, "↑")] {
            assert(SubtitleShortcutPreferences.keyName(for: key, layoutData: frenchData) == label)
        }
        let defaults = UserDefaults(suiteName: "VoxHalo.Shortcuts.Test.\(UUID().uuidString)")!
        var shortcuts = SubtitleShortcutPreferences()
        assert(shortcuts.key(for: .toggle) == 1 && shortcuts.key(for: .up) == 126)
        assert(shortcuts.key(for: .down) == 125 && shortcuts.key(for: .top) == 25 && shortcuts.key(for: .bottom) == 29)
        assert(shortcuts.key(for: .background) == 11)
        assert(shortcuts.key(for: .fontSmaller) == 123 && shortcuts.key(for: .fontLarger) == 124)
        assert(SubtitleShortcutAction.background.id == 6 && SubtitleShortcutAction.fontSmaller.id == 7 && SubtitleShortcutAction.fontLarger.id == 8)
        assert(shortcuts.assign(126, to: .toggle) == false, "duplicate bindings must be rejected")
        assert(shortcuts.assign(20, to: .toggle) == false, "macOS clipboard screenshot keys must be rejected")
        assert(shortcuts.assign(17, to: .toggle) == false, "Finder add-to-Dock shortcut must be rejected")
        assert(shortcuts.assign(0, to: .toggle))
        shortcuts.enabled = false
        try shortcuts.save(to: defaults)
        assert(SubtitleShortcutPreferences.load(from: defaults) == shortcuts)
        defaults.set(Data("{\"enabled\":true,\"keys\":{\"toggle\":126,\"up\":126}}".utf8), forKey: SubtitleShortcutPreferences.storageKey)
        assert(Set(SubtitleShortcutAction.allCases.map { SubtitleShortcutPreferences.load(from: defaults).key(for: $0) }).count == SubtitleShortcutAction.allCases.count,
               "corrupted or partially migrated preferences cannot register duplicate keys")
        let legacy = Data(#"{"enabled":false,"keys":{"toggle":11,"up":126,"down":125,"top":25,"bottom":29}}"#.utf8)
        let migrated = try JSONDecoder().decode(SubtitleShortcutPreferences.self, from: legacy)
        assert(!migrated.enabled && migrated.key(for: .toggle) == 11, "keep existing custom B binding")
        assert(migrated.key(for: .background) != 11)
        assert(Set(SubtitleShortcutAction.allCases.map { migrated.key(for: $0) }).count == SubtitleShortcutAction.allCases.count)
        assert(migrated.key(for: .fontSmaller) == 123 && migrated.key(for: .fontLarger) == 124)
        let sixBindings = Data(#"{"keys":{"toggle":0,"up":12,"down":2,"top":25,"bottom":29,"background":11}}"#.utf8)
        let upgraded = try JSONDecoder().decode(SubtitleShortcutPreferences.self, from: sixBindings)
        assert(upgraded.key(for: .toggle) == 0 && upgraded.key(for: .up) == 12 && upgraded.key(for: .down) == 2)
        assert(upgraded.key(for: .fontSmaller) == 123 && upgraded.key(for: .fontLarger) == 124)
        let partial = try JSONDecoder().decode(SubtitleShortcutPreferences.self, from: Data(#"{"keys":{"toggle":123,"up":11}}"#.utf8))
        assert(partial.key(for: .toggle) == 123 && partial.key(for: .up) == 11, "preserve custom keys that collide with newly added defaults")
        assert(partial.key(for: .fontLarger) == 124 && partial.key(for: .down) == 125, "fallbacks must reserve the other missing defaults")
        assert(Set(SubtitleShortcutAction.allCases.map { partial.key(for: $0) }).count == SubtitleShortcutAction.allCases.count)
        let oldStyle = try JSONDecoder().decode(SubtitlePreferences.self, from: Data(##"{"fontSize":48,"shadowColorHex":"#123456"}"##.utf8))
        assert(!oldStyle.backgroundEnabled && oldStyle.fontSize == 48 && oldStyle.shadowColorHex == "#123456")
        var backgroundStyle = oldStyle.adjusted(for: .background, screenHeight: 0, captionHeight: 0)
        assert(backgroundStyle.backgroundEnabled)
        try backgroundStyle.save(to: defaults)
        assert(SubtitlePreferences.load(from: defaults) == backgroundStyle)
        backgroundStyle.backgroundEnabled = false
        assert(backgroundStyle == oldStyle, "background shortcut must change only the background flag")
        var fontStyle = oldStyle
        fontStyle.enabled = false
        var enlarged = fontStyle.adjusted(for: .fontLarger, screenHeight: 0, captionHeight: 0)
        assert(enlarged.fontSize == 50 && !enlarged.enabled)
        try enlarged.save(to: defaults)
        assert(SubtitlePreferences.load(from: defaults) == enlarged)
        enlarged.fontSize = fontStyle.fontSize
        assert(enlarged == fontStyle, "resizing must preserve visibility, timing mode, colors and position")
        assert(fontStyle.adjusted(for: .fontSmaller, screenHeight: 0, captionHeight: 0).fontSize == 46)
        fontStyle.fontSize = 143
        assert(fontStyle.adjusted(for: .fontLarger, screenHeight: 0, captionHeight: 0).fontSize == 144)
        fontStyle.fontSize = 144
        assert(fontStyle.adjusted(for: .fontLarger, screenHeight: 0, captionHeight: 0) == fontStyle)
        fontStyle.fontSize = 13
        assert(fontStyle.adjusted(for: .fontSmaller, screenHeight: 0, captionHeight: 0).fontSize == 12)
        fontStyle.fontSize = 12
        assert(fontStyle.adjusted(for: .fontSmaller, screenHeight: 0, captionHeight: 0) == fontStyle)
        fontStyle.fontSize = .nan
        assert(fontStyle.adjusted(for: .fontLarger, screenHeight: 0, captionHeight: 0).fontSize == SubtitlePreferences().fontSize + 2)

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
        assert(gesture.press(.background, at: -1) == .background)
        assert(gesture.press(.background, at: -0.9) == nil, "holding B must not flicker the background")
        assert(gesture.repeatAction(at: 0, stillHeld: true) == nil)
        gesture.release(.background)
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
        assert(gesture.press(.fontLarger, at: 6) == .fontLarger)
        assert(gesture.press(.fontLarger, at: 6.1) == nil)
        assert(gesture.repeatAction(at: 6.29, stillHeld: true) == nil)
        assert(gesture.repeatAction(at: 6.31, stillHeld: true) == .fontLarger)
        assert(gesture.repeatAction(at: 6.36, stillHeld: true) == nil, "font repeats must be slower than position movement")
        assert(gesture.repeatAction(at: 6.44, stillHeld: true) == .fontLarger)
        gesture.release(.fontLarger)
        assert(gesture.repeatAction(at: 7, stillHeld: true) == nil)
        assert(gesture.press(.fontSmaller, at: 8) == .fontSmaller)
        assert(gesture.repeatAction(at: 8.4, stillHeld: false) == nil)
        assert(gesture.repeatAction(at: 9, stillHeld: true) == nil)
        print("PASS: shortcut persistence, conflicts, screen geometry, repeat and release safety")
    }
}
