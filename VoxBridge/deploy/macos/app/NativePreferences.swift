import Foundation

struct NativeLanguage: Decodable, Hashable {
    let code: String
    let name: String
    let asrLabel: String
    let ttsLabel: String
    enum CodingKeys: String, CodingKey {
        case code, name
        case asrLabel = "asr_label", ttsLabel = "tts_label"
    }
    static let all: [NativeLanguage] = {
        struct Catalog: Decodable { let version: Int; let languages: [NativeLanguage] }
        // Command-line checks use the same source resource as the built App.
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("voxbridge/language_catalog.json")
        let url = Bundle.main.url(forResource: "language_catalog", withExtension: "json") ?? sourceURL
        do {
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
            guard catalog.version == 1, catalog.languages.count == 8,
                  Set(catalog.languages.map(\.code)).count == catalog.languages.count else {
                fatalError("语言目录格式无效，请重新安装 App。")
            }
            return catalog.languages
        } catch { fatalError("无法加载语言目录，请重新安装 App：\(error)") }
    }()
}

struct NativeTranslationDirection: RawRepresentable, CaseIterable, Hashable {
    let source: NativeLanguage
    let target: NativeLanguage
    var rawValue: String { "\(source.code)2\(target.code)" }
    init?(rawValue: String) {
        let codes = rawValue.components(separatedBy: "2")
        guard codes.count == 2, codes[0] != codes[1],
              let source = NativeLanguage.all.first(where: { $0.code == codes[0] }),
              let target = NativeLanguage.all.first(where: { $0.code == codes[1] }) else { return nil }
        self.source = source; self.target = target
    }
    static let zh2en = NativeTranslationDirection(rawValue: "zh2en")!
    static let en2zh = NativeTranslationDirection(rawValue: "en2zh")!
    static var allCases: [NativeTranslationDirection] {
        NativeLanguage.all.flatMap { source in
            NativeLanguage.all.compactMap { NativeTranslationDirection(rawValue: "\(source.code)2\($0.code)") }
        }
    }
    var sourceLanguage: String { source.asrLabel }
    var targetLanguage: String { target.ttsLabel }
    var sourceName: String { source.name }
    var targetName: String { target.name }
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
