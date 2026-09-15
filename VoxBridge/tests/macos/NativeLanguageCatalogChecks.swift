import Foundation

@main
struct NativeLanguageCatalogChecks {
    static func main() throws {
        assert(NativeLanguage.all.count == 8)
        assert(NativeTranslationDirection.allCases.count == 56)
        assert(Set(NativeTranslationDirection.allCases.map(\.rawValue)).count == 56)
        for pair in NativeTranslationDirection.allCases {
            assert(pair.source != pair.target)
            assert(NativeTranslationDirection(rawValue: pair.rawValue) == pair)
            var preferences = NativePreferences(); preferences.direction = pair.rawValue
            let validated = try preferences.validated()
            assert(validated.languagePair == pair)
            try pair.validateStarted(["translation_direction": pair.rawValue,
                                      "language": pair.sourceLanguage,
                                      "translation_source_language": pair.sourceLanguage,
                                      "translation_target_language": pair.targetLanguage])
        }
        assert(NativeTranslationDirection(rawValue: "ja2ja") == nil)
        assert(NativeTranslationDirection(rawValue: "de2en") == nil)
        assert(NativeTranslationDirection.zh2en.title == "中文 → 英文")
        assert(NativeTranslationDirection.en2zh.title == "英文 → 中文")
        let old = Data(#"{"inputUID":"system-muted","outputUID":"default","direction":"en2zh","contextTerms":[]}"#.utf8)
        let restored = try JSONDecoder().decode(NativePreferences.self, from: old)
        assert(restored.languagePair == .en2zh && restored.inputUID == "system-muted")
        print("Native language catalog: 8 languages / 56 directions / saved preferences passed")
    }
}
