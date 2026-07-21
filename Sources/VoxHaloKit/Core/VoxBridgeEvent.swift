public enum VoxBridgeEventType: Equatable, Sendable {
    case unknown
    case ready
    case started
    case partial
    case sentenceCommitted
    case sentenceUpdated
    case sentenceTranslation
    case sentenceReset
    case translationDirection
    case processing
    case final
    case error
    case pong

    init(rawType: String) {
        self = switch rawType {
        case "ready": .ready
        case "started": .started
        case "partial": .partial
        case "sentence_committed": .sentenceCommitted
        case "sentence_updated": .sentenceUpdated
        case "sentence_translation": .sentenceTranslation
        case "sentence_reset": .sentenceReset
        case "translation_direction": .translationDirection
        case "processing": .processing
        case "final": .final
        case "error": .error
        case "pong": .pong
        default: .unknown
        }
    }
}

public struct VoxBridgeStability: Equatable, Sendable {
    public let isStable: Bool?
    public let phase: String?
    public let reason: String?
    public let sentenceID: String?
    public let segmentID: Int?
    public let sequence: Int?
    public let committedCount: Int?
    public let tentativeCharacters: Int?
    public let unstableCharacters: Int?

    public init(
        isStable: Bool? = nil,
        phase: String? = nil,
        reason: String? = nil,
        sentenceID: String? = nil,
        segmentID: Int? = nil,
        sequence: Int? = nil,
        committedCount: Int? = nil,
        tentativeCharacters: Int? = nil,
        unstableCharacters: Int? = nil
    ) {
        self.isStable = isStable
        self.phase = phase
        self.reason = reason
        self.sentenceID = sentenceID
        self.segmentID = segmentID
        self.sequence = sequence
        self.committedCount = committedCount
        self.tentativeCharacters = tentativeCharacters
        self.unstableCharacters = unstableCharacters
    }
}

public struct VoxBridgeEvent: Equatable, Sendable {
    public let type: VoxBridgeEventType
    public let rawType: String
    public let sentenceID: String?
    public let text: String?
    public let stateText: String?
    public let deltaText: String?
    public let textReset: Bool?
    public let tentativeText: String?
    public let committedText: String?
    public let translation: String?
    public let language: String?
    public let message: String?
    public let reason: String?
    public let translationDirection: String?
    public let translationSourceLanguage: String?
    public let translationTargetLanguage: String?
    public let sequence: Int?
    public let sampleRate: Int?
    public let timestampMilliseconds: Int64?
    public let sliceCommit: Bool?
    public let isStable: Bool?
    public let stability: VoxBridgeStability?

    public init(
        type: VoxBridgeEventType,
        rawType: String,
        sentenceID: String? = nil,
        text: String? = nil,
        stateText: String? = nil,
        deltaText: String? = nil,
        textReset: Bool? = nil,
        tentativeText: String? = nil,
        committedText: String? = nil,
        translation: String? = nil,
        language: String? = nil,
        message: String? = nil,
        reason: String? = nil,
        translationDirection: String? = nil,
        translationSourceLanguage: String? = nil,
        translationTargetLanguage: String? = nil,
        sequence: Int? = nil,
        sampleRate: Int? = nil,
        timestampMilliseconds: Int64? = nil,
        sliceCommit: Bool? = nil,
        isStable: Bool? = nil,
        stability: VoxBridgeStability? = nil
    ) {
        self.type = type
        self.rawType = rawType
        self.sentenceID = sentenceID
        self.text = text
        self.stateText = stateText
        self.deltaText = deltaText
        self.textReset = textReset
        self.tentativeText = tentativeText
        self.committedText = committedText
        self.translation = translation
        self.language = language
        self.message = message
        self.reason = reason
        self.translationDirection = translationDirection
        self.translationSourceLanguage = translationSourceLanguage
        self.translationTargetLanguage = translationTargetLanguage
        self.sequence = sequence
        self.sampleRate = sampleRate
        self.timestampMilliseconds = timestampMilliseconds
        self.sliceCommit = sliceCommit
        self.isStable = isStable
        self.stability = stability
    }
}
