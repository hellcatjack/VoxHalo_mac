import CoreGraphics
import Foundation

public struct SubtitleLayoutSettings: Equatable, Sendable {
    public var targetAreaHeight: CGFloat
    public var targetFontSize: CGFloat
    public var targetTopOffset: CGFloat
    public var targetColor: String
    public var referenceAreaHeight: CGFloat
    public var referenceFontSize: CGFloat
    public var referenceBottomOffset: CGFloat
    public var referenceColor: String

    public init(
        targetAreaHeight: CGFloat,
        targetFontSize: CGFloat,
        targetTopOffset: CGFloat,
        targetColor: String,
        referenceAreaHeight: CGFloat,
        referenceFontSize: CGFloat,
        referenceBottomOffset: CGFloat,
        referenceColor: String
    ) {
        self.targetAreaHeight = targetAreaHeight
        self.targetFontSize = targetFontSize
        self.targetTopOffset = targetTopOffset
        self.targetColor = targetColor
        self.referenceAreaHeight = referenceAreaHeight
        self.referenceFontSize = referenceFontSize
        self.referenceBottomOffset = referenceBottomOffset
        self.referenceColor = referenceColor
    }

    public init(settings: AppSettings) {
        self.init(
            targetAreaHeight: settings.targetAreaHeight,
            targetFontSize: settings.targetFontSize,
            targetTopOffset: settings.targetTopOffset,
            targetColor: settings.targetColor,
            referenceAreaHeight: settings.referenceAreaHeight,
            referenceFontSize: settings.referenceFontSize,
            referenceBottomOffset: settings.referenceBottomOffset,
            referenceColor: settings.referenceColor
        )
    }

    public static let defaults = SubtitleLayoutSettings(
        targetAreaHeight: 264,
        targetFontSize: 36,
        targetTopOffset: 0,
        targetColor: "#FFFFFF",
        referenceAreaHeight: 96,
        referenceFontSize: 24,
        referenceBottomOffset: 0,
        referenceColor: "#F4F4F4"
    )

    public func normalized() -> SubtitleLayoutSettings {
        SubtitleLayoutSettings(
            targetAreaHeight: Self.positive(
                targetAreaHeight,
                default: 264,
                range: 120 ... 640
            ),
            targetFontSize: Self.positive(
                targetFontSize,
                default: 36,
                range: 18 ... 56
            ),
            targetTopOffset: Self.offset(targetTopOffset),
            targetColor: Self.color(targetColor, default: "#FFFFFF"),
            referenceAreaHeight: Self.positive(
                referenceAreaHeight,
                default: 96,
                range: 48 ... 360
            ),
            referenceFontSize: Self.positive(
                referenceFontSize,
                default: 24,
                range: 16 ... 42
            ),
            referenceBottomOffset: Self.offset(referenceBottomOffset),
            referenceColor: Self.color(referenceColor, default: "#F4F4F4")
        )
    }

    private static func positive(
        _ value: CGFloat,
        default defaultValue: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard value.isFinite, value > 0 else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func offset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, 900)
    }

    private static func color(
        _ value: String,
        default defaultValue: String
    ) -> String {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()
        guard normalized.count == 7,
              normalized.first == "#",
              normalized.dropFirst().allSatisfy(\.isHexDigit) else {
            return defaultValue
        }
        return normalized
    }
}
