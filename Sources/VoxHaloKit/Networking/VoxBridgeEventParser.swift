import CoreFoundation
import Foundation

public enum VoxBridgeEventParserError: Error, Equatable {
    case rootIsNotObject
}

public enum VoxBridgeEventParser {
    public static func parse(_ text: String) throws -> VoxBridgeEvent {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> VoxBridgeEvent {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let root = value as? [String: Any] else {
            throw VoxBridgeEventParserError.rootIsNotObject
        }

        let rawType = string(root, "type") ?? ""
        return VoxBridgeEvent(
            type: VoxBridgeEventType(rawType: rawType),
            rawType: rawType,
            sentenceID: string(root, "sentence_id"),
            text: string(root, "text"),
            stateText: string(root, "state_text"),
            deltaText: string(root, "delta_text"),
            textReset: boolean(root, "text_reset"),
            tentativeText: string(root, "tentative_text"),
            committedText: string(root, "committed_text"),
            translation: string(root, "translation"),
            language: string(root, "language"),
            message: string(root, "message"),
            reason: string(root, "reason"),
            translationDirection: string(root, "translation_direction"),
            translationSourceLanguage: string(root, "translation_source_language"),
            translationTargetLanguage: string(root, "translation_target_language"),
            sequence: integer(root, "seq", as: Int.self),
            sampleRate: integer(root, "sample_rate", as: Int.self),
            timestampMilliseconds: integer(root, "ts_ms", as: Int64.self),
            sliceCommit: boolean(root, "slice_commit"),
            isStable: boolean(root, "is_stable"),
            stability: stability(root)
        )
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    private static func boolean(_ object: [String: Any], _ key: String) -> Bool? {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func integer<T: FixedWidthInteger>(
        _ object: [String: Any],
        _ key: String,
        as type: T.Type
    ) -> T? {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else {
            return nil
        }
        return T(exactly: number.int64Value)
    }

    private static func stability(_ root: [String: Any]) -> VoxBridgeStability? {
        guard let value = root["stability"] as? [String: Any] else {
            return nil
        }
        return VoxBridgeStability(
            isStable: boolean(value, "is_stable"),
            phase: string(value, "phase"),
            reason: string(value, "reason"),
            sentenceID: string(value, "sentence_id"),
            segmentID: integer(value, "segment_id", as: Int.self),
            sequence: integer(value, "seq", as: Int.self),
            committedCount: integer(value, "committed_count", as: Int.self),
            tentativeCharacters: integer(value, "tentative_chars", as: Int.self),
            unstableCharacters: integer(value, "unstable_chars", as: Int.self)
        )
    }
}
