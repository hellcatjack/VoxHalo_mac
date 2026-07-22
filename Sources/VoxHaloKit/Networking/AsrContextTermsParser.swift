import Foundation

public enum AsrContextTermsValidationError: LocalizedError, Equatable, Sendable {
    case sentencePunctuation
    case tooManyTerms
    case tooManyJoinedCharacters

    public var errorDescription: String? {
        switch self {
        case .sentencePunctuation:
            "Hotwords cannot contain sentence punctuation; enter individual terms."
        case .tooManyTerms:
            "Hotwords are limited to \(AsrContextTermsParser.maxTerms) terms."
        case .tooManyJoinedCharacters:
            "Hotwords are limited to \(AsrContextTermsParser.maxJoinedCharacters) joined characters."
        }
    }
}

public enum AsrContextTermsParser {
    public static let maxTerms = 24
    public static let maxJoinedCharacters = 160

    private static let sentencePunctuation = Set(
        "。!！?？;；:：".unicodeScalars
    )
    private static let periodTrailingClosers = Set(
        "\"'”’)]）】》".unicodeScalars
    )

    public static func parse(_ raw: String?) throws -> [String] {
        guard let raw else { return [] }

        var terms: [String] = []
        var seen: Set<String> = []
        for component in raw.split(whereSeparator: isSeparator) {
            let term = String(component)
            guard !containsDisallowedSentencePunctuation(term) else {
                throw AsrContextTermsValidationError.sentencePunctuation
            }

            let comparisonKey = term.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(comparisonKey).inserted else { continue }

            terms.append(term)
            guard terms.count <= maxTerms else {
                throw AsrContextTermsValidationError.tooManyTerms
            }
        }

        guard countJoinedCharacters(terms) <= maxJoinedCharacters else {
            throw AsrContextTermsValidationError.tooManyJoinedCharacters
        }
        return terms
    }

    public static func countJoinedCharacters(_ terms: [String]) -> Int {
        terms.reduce(max(0, terms.count - 1)) { count, term in
            count + term.unicodeScalars.count
        }
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == "," || character == "，"
    }

    private static func containsDisallowedSentencePunctuation(
        _ term: String
    ) -> Bool {
        let scalars = Array(term.unicodeScalars)
        if scalars.contains(where: sentencePunctuation.contains) {
            return true
        }
        guard periodOccursAtBoundary(in: scalars) else { return false }
        return !isDottedUppercaseInitialism(scalars)
    }

    private static func periodOccursAtBoundary(
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        guard var index = scalars.indices.last else { return false }
        while periodTrailingClosers.contains(scalars[index]) {
            guard index > scalars.startIndex else { return false }
            scalars.formIndex(before: &index)
        }
        return scalars[index].value == 46
    }

    private static func isDottedUppercaseInitialism(
        _ scalars: [Unicode.Scalar]
    ) -> Bool {
        guard scalars.count >= 4, scalars.count.isMultiple(of: 2) else {
            return false
        }
        for index in stride(from: 0, to: scalars.count, by: 2) {
            guard (65 ... 90).contains(scalars[index].value),
                  scalars[index + 1].value == 46 else {
                return false
            }
        }
        return true
    }
}
