import Foundation
import Carbon

enum SubtitleShortcutAction: String, CaseIterable {
    case toggle, up, down, top, bottom
    var id: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
    var repeats: Bool { self == .up || self == .down }
    var title: String {
        switch self {
        case .toggle: return "显示／隐藏字幕"
        case .up: return "字幕向上移动"
        case .down: return "字幕向下移动"
        case .top: return "字幕移至顶部"
        case .bottom: return "字幕移至底部"
        }
    }
}

/// These shortcuts deliberately keep all three modifiers. Customization changes
/// only the final key, so slide navigation keys are never registered on their own.
struct SubtitleShortcutPreferences: Codable, Equatable {
    static let storageKey = "subtitleShortcuts"
    static let modifiers = UInt32(controlKey | shiftKey | cmdKey)
    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 31: "O", 32: "U", 34: "I",
        35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 126: "↑", 125: "↓"
    ]
    // Omit T (Finder: add to Dock), 3/4/5 (screenshots), and punctuation
    // including = (PowerPoint superscript). Escape/Space/Return/Fn aren't choices.
    static let defaultKeys: [String: UInt32] = ["toggle": 1, "up": 126, "down": 125, "top": 25, "bottom": 29]
    var enabled = true
    private(set) var keys = defaultKeys

    init() {}
    func key(for action: SubtitleShortcutAction) -> UInt32 { keys[action.rawValue] ?? Self.defaultKeys[action.rawValue]! }
    func label(for action: SubtitleShortcutAction) -> String { Self.label(for: key(for: action)) }
    static func label(for key: UInt32) -> String {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            ?? TISGetInputSourceProperty(fallback, kTISPropertyUnicodeKeyLayoutData)
        let data = raw.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() as Data }
        return "⌃⇧⌘ " + keyName(for: key, layoutData: data)
    }
    static func keyName(for key: UInt32, layoutData: Data?) -> String {
        guard key != 125, key != 126, let layoutData else { return keyNames[key] ?? "?" }
        return layoutData.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return keyNames[key] ?? "?" }
            let layout = address.assumingMemoryBound(to: UCKeyboardLayout.self)
            func translate(_ modifiers: UInt32) -> String? {
                var dead: UInt32 = 0, count = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDisplay), modifiers,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &count, &characters)
                guard status == noErr, count > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: count).uppercased()
            }
            let base = translate(0)
            if let base, base.allSatisfy({ $0.isLetter || $0.isNumber }) { return base }
            // On AZERTY the number row requires Shift, already in our prefix.
            if let shifted = translate(UInt32(shiftKey >> 8)), shifted.allSatisfy(\.isNumber) { return shifted }
            return base ?? keyNames[key] ?? "?"
        }
    }
    mutating func assign(_ key: UInt32, to action: SubtitleShortcutAction) -> Bool {
        guard Self.keyNames[key] != nil,
              !SubtitleShortcutAction.allCases.contains(where: { $0 != action && self.key(for: $0) == key }) else { return false }
        keys[action.rawValue] = key; return true
    }
    private enum CodingKeys: String, CodingKey { case enabled, keys }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? true
        let saved = (try? values.decode([String: UInt32].self, forKey: .keys)) ?? Self.defaultKeys
        let candidate = Self.defaultKeys.merging(saved, uniquingKeysWith: { _, new in new })
        let selected = SubtitleShortcutAction.allCases.map { candidate[$0.rawValue]! }
        if Set(selected).count == selected.count && selected.allSatisfy({ Self.keyNames[$0] != nil }) {
            keys = candidate.filter { Self.defaultKeys[$0.key] != nil }
        }
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(to defaults: UserDefaults = .standard) throws { defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey) }
}

extension SubtitlePreferences {
    func adjusted(for action: SubtitleShortcutAction, screenHeight: Double, captionHeight: Double) -> Self {
        var result = self
        switch action {
        case .toggle: result.enabled.toggle()
        case .top: result.verticalPosition = 0
        case .bottom: result.verticalPosition = 1
        case .up, .down:
            let travel = screenHeight - captionHeight
            guard screenHeight.isFinite, captionHeight.isFinite, travel > 0 else { return self }
            result.verticalPosition = min(1, max(0, verticalPosition + (action == .up ? -8 : 8) / travel))
        }
        return result
    }
}

/// Separate press/release state makes toggle idempotent during OS key repeat and
/// lets movement stop immediately even when a key-up was lost during a Space change.
struct SubtitleShortcutGesture {
    private var pressed: Set<SubtitleShortcutAction> = []
    private(set) var repeating: SubtitleShortcutAction?
    private var nextRepeat = 0.0
    mutating func press(_ action: SubtitleShortcutAction, at time: Double) -> SubtitleShortcutAction? {
        guard pressed.insert(action).inserted else { return nil }
        repeating = action.repeats ? action : nil; nextRepeat = time + 0.3
        return action
    }
    mutating func release(_ action: SubtitleShortcutAction) {
        pressed.remove(action)
        if repeating == action { repeating = nil }
    }
    mutating func repeatAction(at time: Double, stillHeld: Bool) -> SubtitleShortcutAction? {
        guard stillHeld else { reset(); return nil }
        guard let action = repeating, time >= nextRepeat else { return nil }
        nextRepeat = time + 0.04; return action
    }
    mutating func reset() { pressed.removeAll(); repeating = nil }
}
