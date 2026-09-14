import CoreGraphics
import Foundation

struct SubtitlePreferences: Codable, Equatable {
    var enabled: Bool = true
    var fontName: String = "PingFangSC-Semibold"
    var fontSize: Double = 36
    var textColorHex: String = "#FFFFFF"
    var shadowEnabled: Bool = true
    var shadowColorHex: String = "#000000"
    var shadowOpacity: Double = 0.9
    var shadowBlur: Double = 4
    var shadowOffset: Double = 2
    var screenID: String = ""
    var horizontalPosition: Double = 0.5
    var verticalPosition: Double = 0.88
    var widthFraction: Double = 0.8

    private static let storageKey = "subtitlePreferences"

    init() {}

    func normalized() -> SubtitlePreferences {
        let defaults = SubtitlePreferences()
        var result = self
        result.fontName = Self.bounded(fontName, fallback: defaults.fontName, rejectsWhitespaceOnly: true)
        result.fontSize = Self.finiteClamped(fontSize, fallback: defaults.fontSize, range: 12...144)
        result.textColorHex = Self.normalizedHex(textColorHex, fallback: defaults.textColorHex)
        result.shadowColorHex = Self.normalizedHex(shadowColorHex, fallback: defaults.shadowColorHex)
        result.shadowOpacity = Self.finiteClamped(shadowOpacity, fallback: defaults.shadowOpacity, range: 0...1)
        result.shadowBlur = Self.finiteClamped(shadowBlur, fallback: defaults.shadowBlur, range: 0...30)
        result.shadowOffset = Self.finiteClamped(shadowOffset, fallback: defaults.shadowOffset, range: 0...20)
        result.screenID = String(screenID.prefix(200))
        result.horizontalPosition = Self.finiteClamped(horizontalPosition, fallback: defaults.horizontalPosition, range: 0...1)
        result.verticalPosition = Self.finiteClamped(verticalPosition, fallback: defaults.verticalPosition, range: 0...1)
        result.widthFraction = Self.finiteClamped(widthFraction, fallback: defaults.widthFraction, range: 0.25...1)
        return result
    }

    static func load(from defaults: UserDefaults = .standard) -> SubtitlePreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SubtitlePreferences.self, from: data) else {
            return SubtitlePreferences()
        }
        return decoded.normalized()
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(normalized()), forKey: Self.storageKey)
    }

    static func frame(in screen: CGRect, size: CGSize, horizontal: Double, vertical: Double) -> CGRect {
        guard screen.origin.x.isFinite, screen.origin.y.isFinite,
              screen.width.isFinite, screen.height.isFinite,
              screen.width >= 0, screen.height >= 0,
              screen.maxX.isFinite, screen.maxY.isFinite else { return .zero }

        let requestedWidth = size.width.isFinite ? max(0, size.width) : 0
        let requestedHeight = size.height.isFinite ? max(0, size.height) : 0
        let insetX = min(20, screen.width / 2)
        let insetY: CGFloat = 0
        let availableWidth = max(0, screen.width - 2 * insetX)
        let availableHeight = max(0, screen.height - 2 * insetY)
        let width = min(requestedWidth, availableWidth)
        let height = min(requestedHeight, availableHeight)
        let horizontal = finiteClamped(horizontal, fallback: 0.5, range: 0...1)
        let vertical = finiteClamped(vertical, fallback: 0.88, range: 0...1)
        let x = screen.minX + insetX + horizontal * (availableWidth - width)
        let y = screen.maxY - insetY - height - vertical * (availableHeight - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, fontName, fontSize, textColorHex, shadowEnabled, shadowColorHex
        case shadowOpacity, shadowBlur, shadowOffset, screenID
        case horizontalPosition, verticalPosition, widthFraction
    }

    init(from decoder: Decoder) throws {
        let defaults = SubtitlePreferences()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? defaults.enabled
        fontName = (try? values.decode(String.self, forKey: .fontName)) ?? defaults.fontName
        fontSize = (try? values.decode(Double.self, forKey: .fontSize)) ?? defaults.fontSize
        textColorHex = (try? values.decode(String.self, forKey: .textColorHex)) ?? defaults.textColorHex
        shadowEnabled = (try? values.decode(Bool.self, forKey: .shadowEnabled)) ?? defaults.shadowEnabled
        shadowColorHex = (try? values.decode(String.self, forKey: .shadowColorHex)) ?? defaults.shadowColorHex
        shadowOpacity = (try? values.decode(Double.self, forKey: .shadowOpacity)) ?? defaults.shadowOpacity
        shadowBlur = (try? values.decode(Double.self, forKey: .shadowBlur)) ?? defaults.shadowBlur
        shadowOffset = (try? values.decode(Double.self, forKey: .shadowOffset)) ?? defaults.shadowOffset
        screenID = (try? values.decode(String.self, forKey: .screenID)) ?? defaults.screenID
        horizontalPosition = (try? values.decode(Double.self, forKey: .horizontalPosition)) ?? defaults.horizontalPosition
        verticalPosition = (try? values.decode(Double.self, forKey: .verticalPosition)) ?? defaults.verticalPosition
        widthFraction = (try? values.decode(Double.self, forKey: .widthFraction)) ?? defaults.widthFraction
    }

    private static func finiteClamped(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private static func normalizedHex(_ value: String, fallback: String) -> String {
        guard value.count == 7, value.first == "#",
              value.dropFirst().unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
              }) else { return fallback }
        return value.uppercased()
    }

    private static func bounded(_ value: String, fallback: String, rejectsWhitespaceOnly: Bool) -> String {
        if rejectsWhitespaceOnly && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback
        }
        return String(value.prefix(200))
    }
}
