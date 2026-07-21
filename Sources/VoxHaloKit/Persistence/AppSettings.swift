import Foundation

public struct AppSettings: Equatable, Sendable {
    public static let publicEndpoint = URL(string: "wss://ushome.amycat.com:18024/ws")!

    public var backendURL: URL
    public var direction: TranslationDirection
    public var preferredAudioDeviceID: String?
    public var preferredDisplayUUID: String?
    public var targetAreaHeight: Double
    public var targetFontSize: Double
    public var targetTopOffset: Double
    public var targetColor: String
    public var authUsername: String
    public var referenceAreaHeight: Double
    public var referenceFontSize: Double
    public var referenceBottomOffset: Double
    public var referenceColor: String
    public var unknownFields: [String: JSONValue]

    public init(
        backendURL: URL = AppSettings.publicEndpoint,
        direction: TranslationDirection = .chineseToEnglish,
        preferredAudioDeviceID: String? = nil,
        preferredDisplayUUID: String? = nil,
        targetAreaHeight: Double = 264,
        targetFontSize: Double = 36,
        targetTopOffset: Double = 0,
        targetColor: String = "#FFFFFF",
        authUsername: String = "admin",
        referenceAreaHeight: Double = 96,
        referenceFontSize: Double = 24,
        referenceBottomOffset: Double = 0,
        referenceColor: String = "#F4F4F4",
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.backendURL = backendURL
        self.direction = direction
        self.preferredAudioDeviceID = preferredAudioDeviceID
        self.preferredDisplayUUID = preferredDisplayUUID
        self.targetAreaHeight = targetAreaHeight
        self.targetFontSize = targetFontSize
        self.targetTopOffset = targetTopOffset
        self.targetColor = targetColor
        self.authUsername = authUsername
        self.referenceAreaHeight = referenceAreaHeight
        self.referenceFontSize = referenceFontSize
        self.referenceBottomOffset = referenceBottomOffset
        self.referenceColor = referenceColor
        self.unknownFields = unknownFields
    }

    public static var defaults: AppSettings { AppSettings() }

    public static func sanitizedEndpoint(_ endpoint: URL) -> URL {
        if endpoint.absoluteString.caseInsensitiveCompare(
            "ws://192.168.1.31:8024/ws"
        ) == .orderedSame {
            return publicEndpoint
        }

        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        scheme == "ws" || scheme == "wss",
        let host = components.host,
        !host.isEmpty else {
            return publicEndpoint
        }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.fragment = nil

        if let queryItems = components.queryItems {
            let safeItems = queryItems.filter {
                !sensitiveQueryNames.contains($0.name.lowercased())
            }
            components.queryItems = safeItems.isEmpty ? nil : safeItems
        }

        return components.url ?? publicEndpoint
    }

    func normalized() -> AppSettings {
        AppSettings(
            backendURL: Self.sanitizedEndpoint(backendURL),
            direction: direction,
            preferredAudioDeviceID: Self.nonblank(preferredAudioDeviceID),
            preferredDisplayUUID: Self.nonblank(preferredDisplayUUID),
            targetAreaHeight: Self.normalizePositive(
                targetAreaHeight,
                default: 264,
                range: 120 ... 640
            ),
            targetFontSize: Self.normalizePositive(
                targetFontSize,
                default: 36,
                range: 18 ... 56
            ),
            targetTopOffset: Self.normalizeOffset(targetTopOffset),
            targetColor: Self.normalizeColor(targetColor, default: "#FFFFFF"),
            authUsername: Self.nonblank(authUsername) ?? "admin",
            referenceAreaHeight: Self.normalizePositive(
                referenceAreaHeight,
                default: 96,
                range: 48 ... 360
            ),
            referenceFontSize: Self.normalizePositive(
                referenceFontSize,
                default: 24,
                range: 16 ... 42
            ),
            referenceBottomOffset: Self.normalizeOffset(referenceBottomOffset),
            referenceColor: Self.normalizeColor(referenceColor, default: "#F4F4F4"),
            unknownFields: unknownFields
        )
    }

    private static let sensitiveQueryNames: Set<String> = [
        "token", "access_token", "refresh_token", "id_token", "session_token",
        "api_key", "apikey", "password", "passwd", "secret", "client_secret",
        "authorization"
    ]

    private static func normalizePositive(
        _ value: Double,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite, value > 0 else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalizeOffset(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, 900)
    }

    private static func normalizeColor(_ value: String, default defaultValue: String) -> String {
        let color = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard color.count == 7, color.first == "#",
              color.dropFirst().allSatisfy(\.isHexDigit) else {
            return defaultValue
        }
        return color
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
