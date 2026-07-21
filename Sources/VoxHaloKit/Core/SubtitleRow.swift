public struct SubtitleRow: Equatable, Sendable {
    public let sentenceID: String
    public let sourceText: String
    public let translation: String
    public let sequence: Int
    public let timestampMilliseconds: Int64?

    public init(
        sentenceID: String,
        sourceText: String,
        translation: String,
        sequence: Int,
        timestampMilliseconds: Int64?
    ) {
        self.sentenceID = sentenceID
        self.sourceText = sourceText
        self.translation = translation
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
    }
}
