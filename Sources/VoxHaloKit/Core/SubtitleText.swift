import Foundation

enum SubtitleText {
    static let maximumPrimarySegments = 96
    static let maximumReferenceSegments = 24

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func normalizedSegments<S: Sequence>(
        _ values: S,
        limit: Int
    ) -> [String]
    where S.Element == String {
        values.lazy
            .map(normalized)
            .filter { !$0.isEmpty }
            .suffix(max(0, limit))
    }

    static func joined(_ segments: [String]) -> String {
        normalized(segments.joined(separator: " "))
    }
}
