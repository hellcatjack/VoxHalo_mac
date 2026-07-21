import Foundation

public enum AudioSourceKind: String, Codable, Sendable {
    case systemAudio
    case hardwareInput
}

public struct AudioSource: Identifiable, Codable, Hashable, Sendable {
    public static let systemAudioID = "system-default-loopback"
    public static let systemAudio = AudioSource(
        id: systemAudioID,
        name: "System Audio",
        kind: .systemAudio
    )

    public let id: String
    public let name: String
    public let kind: AudioSourceKind

    public init(id: String, name: String, kind: AudioSourceKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public enum AudioSourceSelection {
    public static func preferred(
        from sources: [AudioSource],
        savedID: String?
    ) -> AudioSource? {
        if let savedID, let saved = sources.first(where: { $0.id == savedID }) {
            return saved
        }
        return sources.first(where: { $0.id == AudioSource.systemAudioID })
            ?? sources.first
    }
}

public protocol AudioSourceValidating: Sendable {
    func validateAvailable(_ source: AudioSource) throws
}
