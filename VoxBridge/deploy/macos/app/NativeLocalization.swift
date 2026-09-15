import Foundation

/// Presentation-only localization. It never modifies audio or translation preferences.
enum NativeLocalization {
    static let codes = ["zh", "en", "ja", "fr", "es", "it", "pt", "hi"]
    static let autonyms = ["中文", "English", "日本語", "Français", "Español", "Italiano", "Português", "हिन्दी"]
    static let preferenceKey = "interfaceLanguage"

    static func resolve(preference: String, preferred: [String]) -> String {
        if codes.contains(preference) { return preference }
        for candidate in preferred {
            let base = candidate.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
            if codes.contains(base) { return base }
        }
        return "en"
    }
    static func preference(in defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: preferenceKey) ?? "auto"
        return codes.contains(value) ? value : "auto"
    }
    static func save(_ value: String, to defaults: UserDefaults = .standard) {
        defaults.set(codes.contains(value) ? value : "auto", forKey: preferenceKey)
    }
    static var locale: String { resolve(preference: preference(), preferred: Locale.preferredLanguages) }

    private struct Catalog: Decodable { let version: Int; let messages: [String: [String: String]] }
    static let messages: [String: [String: String]] = {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("voxbridge/ui_locales")
        let directory = Bundle.main.resourceURL?.appendingPathComponent("ui_locales")
        var result: [String: [String: String]] = [:]
        for name in ["native", "native-errors", "installer"] {
            let bundled = directory?.appendingPathComponent(name + ".json")
            let url = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? source.appendingPathComponent(name + ".json")
            if let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data), catalog.version == 1 {
                result.merge(catalog.messages, uniquingKeysWith: { original, _ in original })
            }
        }
        return result
    }()
    private static let placeholder = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    private struct Pattern { let source: String; let regex: NSRegularExpression; let indices: [Int]; let specificity: Int }
    private static let patterns: [Pattern] = messages.keys.compactMap { source in
        let matches = placeholder.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return nil }
        let raw = source as NSString
        var expression = "^", end = 0, indices: [Int] = [], specificity = 0
        for match in matches {
            let literal = raw.substring(with: NSRange(location: end, length: match.range.location - end))
            expression += NSRegularExpression.escapedPattern(for: literal) + "(.*?)"
            specificity += literal.count
            indices.append(Int(raw.substring(with: match.range(at: 1)))!)
            end = NSMaxRange(match.range)
        }
        let tail = raw.substring(from: end)
        expression += NSRegularExpression.escapedPattern(for: tail) + "$"; specificity += tail.count
        guard let regex = try? NSRegularExpression(pattern: expression, options: .dotMatchesLineSeparators) else { return nil }
        return Pattern(source: source, regex: regex, indices: indices, specificity: specificity)
    }.sorted { $0.specificity == $1.specificity ? $0.source < $1.source : $0.specificity > $1.specificity }

    static func hasMessage(_ source: String) -> Bool {
        messages[source] != nil || patterns.contains { $0.regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil }
    }
    private static func format(_ template: String, arguments: [String]) -> String {
        let raw = template as NSString
        var result = "", end = 0
        for match in placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            result += raw.substring(with: NSRange(location: end, length: match.range.location - end))
            let index = Int(raw.substring(with: match.range(at: 1)))!
            result += arguments.indices.contains(index) ? arguments[index] : raw.substring(with: match.range)
            end = NSMaxRange(match.range)
        }
        return result + raw.substring(from: end)
    }
    static func text(_ source: String, _ arguments: String...) -> String {
        let selected = locale
        let template = messages[source]?[selected] ?? messages[source]?["en"] ?? source
        return format(template, arguments: arguments.map { translate($0, locale: selected) })
    }
    static func translate(_ source: String, locale selected: String, depth: Int = 0) -> String {
        guard !source.isEmpty, depth < 4, selected != "zh" else { return source }
        if let value = messages[source] { return value[selected] ?? value["en"] ?? source }
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { continue }
            var args = Array(repeating: "", count: (pattern.indices.max() ?? -1) + 1)
            for (offset, index) in pattern.indices.enumerated() {
                args[index] = translate((source as NSString).substring(with: match.range(at: offset + 1)), locale: selected, depth: depth + 1)
            }
            let template = messages[pattern.source]?[selected] ?? messages[pattern.source]?["en"] ?? pattern.source
            return format(template, arguments: args)
        }
        return source
    }
    static func render(_ source: String) -> String { translate(source, locale: locale) }
}
