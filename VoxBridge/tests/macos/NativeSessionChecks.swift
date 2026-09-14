import Foundation

@main struct Checks {
    static func main() throws {
        let name = "native-session-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        assert(NativePreferences.load(from: defaults).inputUID == "system")
        var preferences = NativePreferences()
        preferences.inputUID = "microphone-stable-uid"; preferences.outputUID = "headphones-stable-uid"
        preferences.direction = "en2zh"; preferences.contextTerms = [" PCCS ", "圣经"]
        preferences = try preferences.validated(); try preferences.save(to: defaults)
        assert(NativePreferences.load(from: defaults) == preferences)
        assert(preferences.contextTerms == ["PCCS", "圣经"])
        for pair in NativeTranslationDirection.allCases {
            var started: [String: Any] = ["translation_direction": pair.rawValue,
                "language": pair.sourceLanguage, "translation_source_language": pair.sourceLanguage,
                "translation_target_language": pair.targetLanguage]
            try pair.validateStarted(started)
            for field in ["translation_direction", "language", "translation_source_language", "translation_target_language"] {
                let previous = started[field]
                started[field] = "wrong"
                do { try pair.validateStarted(started); assertionFailure("mismatched \(field) accepted") } catch {}
                started.removeValue(forKey: field)
                do { try pair.validateStarted(started); assertionFailure("missing \(field) accepted") } catch {}
                started[field] = previous
            }
        }
        preferences.contextTerms = ["尼希米 同工", "PCCS\t教会\n圣经"]
        preferences = try preferences.validated()
        assert(preferences.contextTerms == ["尼希米", "同工", "PCCS", "教会", "圣经"], "whitespace-separated terms must not be rejected by the ASR server")
        preferences.contextTerms = [Array(repeating: "词", count: 25).joined(separator: " ")]
        do { _ = try preferences.validated(); assertionFailure("term limit must apply after splitting") } catch {}
        preferences.contextTerms = [String(repeating: "甲", count: 161)]
        do { _ = try preferences.validated(); assertionFailure("oversized context accepted") } catch {}
        var queue = NativePCMQueue(capacityBytes: 8)
        let first = Data([0,1,2,3]), second = Data([4,5,6,7])
        try queue.append(first); try queue.append(second)
        do { try queue.append(Data([8,9])); assertionFailure("overflow accepted") } catch {}
        assert(queue.byteCount == 8 && queue.next() == first && queue.next() == second)
        assert(queue.next() == nil && queue.byteCount == 0)
        do { try queue.append(Data([1])); assertionFailure("odd PCM accepted") } catch {}
        try queue.append(first); queue.reset(); assert(queue.byteCount == 0 && queue.next() == nil)
        print("Native preference and ordered bounded PCM checks passed")
    }
}
