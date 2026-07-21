import Foundation

public enum VoxBridgeMessageEncoder {
    public static func start(_ direction: TranslationDirection) throws -> Data {
        try encoder.encode(StartMessage(
            type: "start",
            language: direction.backendLanguage,
            translationDirection: direction.backendDirection
        ))
    }

    public static func setTranslationDirection(_ direction: TranslationDirection) throws -> Data {
        try encoder.encode(DirectionMessage(
            type: "set_translation_direction",
            translationDirection: direction.backendDirection
        ))
    }

    public static func finish() throws -> Data {
        try encoder.encode(FinishMessage(type: "finish"))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct StartMessage: Encodable {
    let type: String
    let language: String
    let translationDirection: String

    enum CodingKeys: String, CodingKey {
        case type
        case language
        case translationDirection = "translation_direction"
    }
}

private struct DirectionMessage: Encodable {
    let type: String
    let translationDirection: String

    enum CodingKeys: String, CodingKey {
        case type
        case translationDirection = "translation_direction"
    }
}

private struct FinishMessage: Encodable {
    let type: String
}
