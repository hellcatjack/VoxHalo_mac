import Foundation

public struct SubtitleColorChoice: Identifiable, Equatable, Sendable {
    public let name: String
    public let hex: String

    public var id: String { hex }

    public init(name: String, hex: String) {
        self.name = name
        self.hex = hex
    }

    public static let all: [SubtitleColorChoice] = [
        SubtitleColorChoice(name: "White", hex: "#FFFFFF"),
        SubtitleColorChoice(name: "Soft White", hex: "#F4F4F4"),
        SubtitleColorChoice(name: "Warm Yellow", hex: "#FFD966"),
        SubtitleColorChoice(name: "Cyan", hex: "#8FE8FF"),
        SubtitleColorChoice(name: "Soft Green", hex: "#B7F7C4"),
        SubtitleColorChoice(name: "Pink", hex: "#FFB3D1"),
    ]
}
