import Foundation

enum SubtitleText {
    static let maximumSegments = 24
    static let maximumPrimaryUTF16Units = 480

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func normalizedSegments<S: Sequence>(_ values: S) -> [String]
    where S.Element == String {
        values.lazy
            .map(normalized)
            .filter { !$0.isEmpty }
            .suffix(maximumSegments)
    }

    static func recentWindow(_ text: String, maximumUTF16Units: Int = maximumPrimaryUTF16Units) -> String {
        let clean = normalized(text)
        guard clean.utf16.count > maximumUTF16Units else {
            return clean
        }

        var start = clean.endIndex
        var retainedUnits = 0
        while start > clean.startIndex {
            let previous = clean.index(before: start)
            let characterUnits = clean[previous..<start].utf16.count
            guard retainedUnits + characterUnits <= maximumUTF16Units else {
                break
            }
            retainedUnits += characterUnits
            start = previous
        }

        return "..." + clean[start...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func joined(_ segments: [String]) -> String {
        normalized(segments.joined(separator: " "))
    }
}
