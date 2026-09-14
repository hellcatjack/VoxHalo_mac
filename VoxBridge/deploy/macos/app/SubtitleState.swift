import Foundation

struct CompletedSubtitleState {
    struct Identity: Equatable { let sentenceID: String; let revision: Int; var speechSequence: Int? = nil }
    private(set) var identity: Identity?
    private struct SourceSentence {
        var revision: Int
        var sourceText: String
        var order: UInt64
    }

    private static let metadataLimit = 300

    private(set) var text: String = ""
    private var sources: [String: SourceSentence] = [:]
    private var nextOrder: UInt64 = 0
    private var displayedSentenceID: String?
    private var latestDisplayedOrder: UInt64?

    mutating func observe(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "started", "sentence_reset":
            reset()
        case "sentence_committed", "sentence_updated":
            observeSource(event)
        case "sentence_translation":
            observeTranslation(event)
        default:
            break
        }
    }

    mutating func reset() {
        text = ""; identity = nil
        sources.removeAll(keepingCapacity: true)
        nextOrder = 0
        displayedSentenceID = nil
        latestDisplayedOrder = nil
    }

    private mutating func observeSource(_ event: [String: Any]) {
        guard let id = event["sentence_id"] as? String, !id.isEmpty,
              let revision = Self.integer(event["revision"]), revision >= 0,
              let sourceText = event["text"] as? String else { return }

        if var existing = sources[id] {
            guard revision >= existing.revision else { return }
            let changed = revision != existing.revision || sourceText != existing.sourceText
            existing.revision = revision
            existing.sourceText = sourceText
            sources[id] = existing
            if changed, displayedSentenceID == id {
                text = ""; identity = nil
            }
            return
        }

        if displayedSentenceID == id {
            text = ""; identity = nil
        }
        let order = allocateOrder()
        sources[id] = SourceSentence(revision: revision, sourceText: sourceText, order: order)
        evictOldestSourceIfNeeded()
    }

    private mutating func observeTranslation(_ event: [String: Any]) {
        guard Self.strictTrue(event["is_stable"]),
              let id = event["sentence_id"] as? String,
              let revision = Self.integer(event["revision"]),
              let translatedText = event["translation"] as? String, !translatedText.isEmpty,
              let source = sources[id], source.revision == revision else { return }
        if let latestDisplayedOrder, source.order < latestDisplayedOrder { return }

        identity = Identity(sentenceID: id, revision: revision)
        text = translatedText
        displayedSentenceID = id
        latestDisplayedOrder = source.order
    }

    private mutating func allocateOrder() -> UInt64 {
        if nextOrder == UInt64.max {
            let orderedIDs = sources.keys.sorted {
                sources[$0]!.order < sources[$1]!.order
            }
            for (index, id) in orderedIDs.enumerated() {
                sources[id]!.order = UInt64(index)
            }
            if let displayedSentenceID, let displayed = sources[displayedSentenceID] {
                latestDisplayedOrder = displayed.order
            } else {
                latestDisplayedOrder = nil
            }
            nextOrder = UInt64(orderedIDs.count)
        }
        let result = nextOrder
        nextOrder += 1
        return result
    }

    private mutating func evictOldestSourceIfNeeded() {
        guard sources.count > Self.metadataLimit,
              let oldest = sources.min(by: { $0.value.order < $1.value.order }) else { return }
        sources.removeValue(forKey: oldest.key)
    }

    private static func strictTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }
}
