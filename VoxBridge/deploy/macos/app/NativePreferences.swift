import Foundation

enum NativeTranslationDirection: String, CaseIterable {
    case zh2en, en2zh
    var sourceLanguage: String { self == .zh2en ? "Chinese" : "English" }
    var targetLanguage: String { self == .zh2en ? "English" : "Chinese" }
    var sourceName: String { self == .zh2en ? "中文" : "英文" }
    var targetName: String { self == .zh2en ? "英文" : "中文" }
    var title: String { "\(sourceName) → \(targetName)" }

    func validateStarted(_ event: [String: Any]) throws {
        guard event["translation_direction"] as? String == rawValue,
              event["language"] as? String == sourceLanguage,
              event["translation_source_language"] as? String == sourceLanguage,
              event["translation_target_language"] as? String == targetLanguage else {
            throw ServiceError.message("服务的识别或翻译语言与所选“\(title)”不一致，已取消采集。请重新启动服务。")
        }
    }
}

struct NativePreferences: Codable, Equatable {
    var inputUID = "system"
    var outputUID = "default"
    var direction = "zh2en"
    var contextTerms: [String] = []
    var languagePair: NativeTranslationDirection { NativeTranslationDirection(rawValue: direction) ?? .zh2en }
    var usesSystemAudio: Bool { inputUID == "system" || inputUID == "system-muted" }

    static func load(from defaults: UserDefaults = .standard) -> NativePreferences {
        guard let data = defaults.data(forKey: "nativeAudioPreferences"),
              let result = try? JSONDecoder().decode(NativePreferences.self, from: data) else { return NativePreferences() }
        return result
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "nativeAudioPreferences")
    }

    func validated() throws -> NativePreferences {
        guard NativeTranslationDirection(rawValue: direction) != nil else { throw ServiceError.message("请选择翻译方向。") }
        guard !inputUID.isEmpty, !outputUID.isEmpty else { throw ServiceError.message("请选择输入和输出设备。") }
        let terms = contextTerms.flatMap { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        guard terms.count <= 24, terms.joined(separator: " ").count <= 160 else {
            throw ServiceError.message("ASR 提示词最多 24 项，合计不超过 160 个字符。")
        }
        var result = self; result.contextTerms = terms
        return result
    }
}

/// A finite transport buffer; overflow stops the session instead of losing speech silently.
struct NativePCMQueue {
    let capacityBytes: Int
    private var buffers: [Data] = []
    private(set) var byteCount = 0
    init(capacityBytes: Int = 160_000) { self.capacityBytes = capacityBytes }
    mutating func append(_ data: Data) throws {
        guard !data.isEmpty, data.count % 2 == 0 else { throw ServiceError.message("采集音频格式无效。") }
        guard byteCount + data.count <= capacityBytes else { throw ServiceError.message("音频发送积压超过 5 秒，已停止采集。请检查本机服务。") }
        buffers.append(data); byteCount += data.count
    }
    mutating func next() -> Data? {
        guard !buffers.isEmpty else { return nil }
        let data = buffers.removeFirst(); byteCount -= data.count; return data
    }
    mutating func reset() { buffers.removeAll(); byteCount = 0 }
}
