import Foundation

@main
struct NativeLocalizationChecks {
    static func main() {
        assert(NativeLocalization.resolve(preference: "auto", preferred: ["de-DE", "ja-JP"]) == "ja")
        assert(NativeLocalization.resolve(preference: "auto", preferred: ["zh-Hant-TW"]) == "zh")
        assert(NativeLocalization.resolve(preference: "auto", preferred: ["pt_BR"]) == "pt")
        assert(NativeLocalization.resolve(preference: "auto", preferred: ["de"]) == "en")
        assert(NativeLocalization.resolve(preference: "fr", preferred: ["zh"]) == "fr")
        assert(NativeLocalization.resolve(preference: "invalid", preferred: ["es-MX"]) == "es")
        for locale in NativeLocalization.codes {
            assert(NativeLocalization.translate("启动服务", locale: locale) != "")
            let label = NativeLocalization.translate("已断开 · device-123", locale: locale)
            assert(label.contains("device-123"))
            assert(!label.contains("{0}"))
        }
        assert(NativeLocalization.translate("启动服务", locale: "en") == "Start services")
        assert(NativeLocalization.translate("已断开 · USB {0}", locale: "en") == "Disconnected · USB {0}")
        assert(NativeLocalization.translate("英文 → 中文", locale: "en") == "English → Chinese")
        assert(NativeLocalization.translate("unknown technical detail <script>", locale: "ja") == "unknown technical detail <script>")
        let defaults = UserDefaults(suiteName: "voxhalo.localization.test.\(UUID().uuidString)")!
        assert(NativeLocalization.preference(in: defaults) == "auto")
        NativeLocalization.save("hi", to: defaults)
        assert(NativeLocalization.preference(in: defaults) == "hi")
        NativeLocalization.save("invalid", to: defaults)
        assert(NativeLocalization.preference(in: defaults) == "auto")
        print("Native localization: resolution, persistence, placeholders and nested labels passed")
    }
}
