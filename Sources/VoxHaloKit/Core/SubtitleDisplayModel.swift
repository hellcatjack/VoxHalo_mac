public struct SubtitleDisplayModel: Equatable, Sendable {
    public let stablePrimaryLines: [String]
    public let activePrimaryText: String
    public let referenceText: String
    public let targetLanguage: String
    public let sourceLanguage: String
    public let isProcessing: Bool
    public let primarySegments: [String]
    public let referenceSegments: [String]
    public let stablePrimaryText: String
    public let primaryText: String

    public init(
        stablePrimaryLines: [String],
        activePrimaryText: String,
        referenceText: String,
        referenceSegments: [String]? = nil,
        targetLanguage: String,
        sourceLanguage: String,
        isProcessing: Bool
    ) {
        let stable = stablePrimaryLines.map(SubtitleText.normalized).filter { !$0.isEmpty }
        let active = SubtitleText.normalized(activePrimaryText)
        let allPrimary = SubtitleText.normalizedSegments(
            stable + (active.isEmpty ? [] : [active]),
            limit: SubtitleText.maximumPrimarySegments
        )

        if active.isEmpty {
            self.stablePrimaryLines = allPrimary
            self.activePrimaryText = ""
        } else {
            self.stablePrimaryLines = Array(allPrimary.dropLast())
            self.activePrimaryText = allPrimary.last ?? ""
        }

        self.primarySegments = allPrimary
        self.stablePrimaryText = SubtitleText.joined(self.stablePrimaryLines)
        self.primaryText = SubtitleText.joined(allPrimary)
        self.referenceText = SubtitleText.normalized(referenceText)

        let suppliedReference = SubtitleText.normalizedSegments(
            referenceSegments ?? [],
            limit: SubtitleText.maximumReferenceSegments
        )
        self.referenceSegments = suppliedReference.isEmpty
            ? SubtitleText.normalizedSegments(
                [self.referenceText],
                limit: SubtitleText.maximumReferenceSegments
            )
            : suppliedReference

        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.isProcessing = isProcessing
    }

    public init(
        primaryText: String,
        referenceText: String,
        targetLanguage: String,
        sourceLanguage: String,
        isProcessing: Bool
    ) {
        self.init(
            stablePrimaryLines: [],
            activePrimaryText: primaryText,
            referenceText: referenceText,
            targetLanguage: targetLanguage,
            sourceLanguage: sourceLanguage,
            isProcessing: isProcessing
        )
    }

    public static func empty(for direction: TranslationDirection) -> Self {
        SubtitleDisplayModel(
            stablePrimaryLines: [],
            activePrimaryText: "",
            referenceText: "",
            targetLanguage: direction.targetLanguageLabel,
            sourceLanguage: direction.sourceLanguageLabel,
            isProcessing: false
        )
    }

    init(
        cachedPrimarySegments: [String],
        cachedReferenceSegments: [String],
        referenceText: String,
        targetLanguage: String,
        sourceLanguage: String,
        isProcessing: Bool
    ) {
        let primary = cachedPrimarySegments.count <= SubtitleText.maximumPrimarySegments
            ? cachedPrimarySegments
            : Array(cachedPrimarySegments.suffix(SubtitleText.maximumPrimarySegments))
        self.primarySegments = primary
        self.stablePrimaryLines = primary.isEmpty ? [] : Array(primary.dropLast())
        self.activePrimaryText = primary.last ?? ""
        self.stablePrimaryText = SubtitleText.joined(stablePrimaryLines)
        self.primaryText = SubtitleText.joined(primary)
        self.referenceText = SubtitleText.normalized(referenceText)
        self.referenceSegments = cachedReferenceSegments.count <= SubtitleText.maximumReferenceSegments
            ? cachedReferenceSegments
            : Array(cachedReferenceSegments.suffix(SubtitleText.maximumReferenceSegments))
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.isProcessing = isProcessing
    }
}
