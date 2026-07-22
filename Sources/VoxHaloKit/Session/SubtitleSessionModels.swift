import Foundation

public struct SubtitleSessionConfiguration: Equatable, Sendable {
    public let endpoint: VoxBridgeEndpoint
    public let direction: TranslationDirection
    public let audioSource: AudioSource
    public let credentials: VoxBridgeAuthCredentials?
    public let asrContextTerms: [String]

    public init(
        endpoint: VoxBridgeEndpoint,
        direction: TranslationDirection,
        audioSource: AudioSource,
        credentials: VoxBridgeAuthCredentials?,
        asrContextTerms: [String] = []
    ) {
        self.endpoint = endpoint
        self.direction = direction
        self.audioSource = audioSource
        self.credentials = credentials
        self.asrContextTerms = Array(asrContextTerms)
    }
}

public struct SubtitleSessionPolicy: Equatable, Sendable {
    public var finalWaitTimeout: Duration
    public var callbackGapThreshold: Duration

    public init(
        finalWaitTimeout: Duration = .seconds(120),
        callbackGapThreshold: Duration = .seconds(480)
    ) {
        self.finalWaitTimeout = finalWaitTimeout
        self.callbackGapThreshold = callbackGapThreshold
    }
}

public enum SubtitleSessionState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case finishing
}

public enum SubtitleSessionOutput: Equatable, Sendable {
    case state(SubtitleSessionState)
    case subtitle(SubtitleDisplayModel)
    case status(String)
    case failure(String)
}

public enum SubtitleSessionError: LocalizedError, Equatable, Sendable {
    case alreadyActive
    case backendRejected(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyActive:
            "A subtitle session is already active."
        case let .backendRejected(message):
            "Start failed: \(message)"
        }
    }
}

public protocol SubtitleSessionCoordinating: Sendable {
    func outputs() async -> AsyncStream<SubtitleSessionOutput>
    func start(_ configuration: SubtitleSessionConfiguration) async throws
    func stop() async
}

public typealias SubtitleSessionEndpointValidator = @Sendable (
    VoxBridgeEndpoint
) throws -> VoxBridgeEndpoint
