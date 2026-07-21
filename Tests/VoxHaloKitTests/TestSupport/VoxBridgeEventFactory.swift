import Foundation
@testable import VoxHaloKit

extension VoxBridgeEvent {
    static func committed(
        _ id: String,
        _ text: String,
        sequence: Int,
        isStable: Bool? = nil,
        stability: VoxBridgeStability? = nil
    ) -> Self {
        VoxBridgeEvent(
            type: .sentenceCommitted,
            rawType: "sentence_committed",
            sentenceID: id,
            text: text,
            sequence: sequence,
            isStable: isStable,
            stability: stability
        )
    }

    static func updated(_ id: String, _ text: String, sequence: Int) -> Self {
        VoxBridgeEvent(
            type: .sentenceUpdated,
            rawType: "sentence_updated",
            sentenceID: id,
            text: text,
            sequence: sequence
        )
    }

    static func translated(_ id: String, _ text: String, sequence: Int) -> Self {
        VoxBridgeEvent(
            type: .sentenceTranslation,
            rawType: "sentence_translation",
            sentenceID: id,
            translation: text,
            sequence: sequence
        )
    }

    static func partial(
        text: String? = nil,
        state: String? = nil,
        delta: String? = nil,
        reset: Bool? = nil,
        tentative: String? = nil,
        committed: String? = nil,
        translation: String? = nil,
        sequence: Int = 1
    ) -> Self {
        VoxBridgeEvent(
            type: .partial,
            rawType: "partial",
            text: text,
            stateText: state,
            deltaText: delta,
            textReset: reset,
            tentativeText: tentative,
            committedText: committed,
            translation: translation,
            sequence: sequence
        )
    }

    static func reset(reason: String? = nil) -> Self {
        VoxBridgeEvent(type: .sentenceReset, rawType: "sentence_reset", reason: reason)
    }

    static func processing() -> Self {
        VoxBridgeEvent(type: .processing, rawType: "processing")
    }

    static func final(
        text: String? = nil,
        committed: String? = nil,
        translation: String? = nil,
        sequence: Int = 1
    ) -> Self {
        VoxBridgeEvent(
            type: .final,
            rawType: "final",
            text: text,
            committedText: committed,
            translation: translation,
            sequence: sequence
        )
    }
}

func addTranslatedSentence(
    _ store: inout SubtitleStateStore,
    id: String,
    source: String,
    translation: String,
    sequence: Int
) {
    store.apply(.committed(id, source, sequence: sequence))
    store.apply(.translated(id, translation, sequence: sequence + 1))
}

func makeTranslatedStore(
    direction: TranslationDirection = .englishToChinese,
    _ values: (String, String, String)...
) -> SubtitleStateStore {
    var store = SubtitleStateStore(direction: direction)
    for (index, value) in values.enumerated() {
        addTranslatedSentence(
            &store,
            id: value.0,
            source: value.1,
            translation: value.2,
            sequence: index * 2 + 1
        )
    }
    return store
}
