public enum TranslationDirection: Int, Codable, CaseIterable, Sendable {
    case chineseToEnglish = 0
    case englishToChinese = 1

    public var backendLanguage: String {
        switch self {
        case .chineseToEnglish: "Chinese"
        case .englishToChinese: "English"
        }
    }

    public var backendDirection: String {
        switch self {
        case .chineseToEnglish: "zh2en"
        case .englishToChinese: "en2zh"
        }
    }

    public var targetLanguageLabel: String {
        switch self {
        case .chineseToEnglish: "English"
        case .englishToChinese: "Chinese"
        }
    }

    public var sourceLanguageLabel: String {
        switch self {
        case .chineseToEnglish: "Chinese"
        case .englishToChinese: "English"
        }
    }
}
