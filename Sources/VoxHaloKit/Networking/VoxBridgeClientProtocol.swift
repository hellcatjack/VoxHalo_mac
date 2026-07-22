import Foundation

public enum VoxBridgeConnectionEvent: Equatable, Sendable {
    case connected
    case disconnected
    case parseError
    case receiveError(String)
}

public enum VoxBridgeClientOutput: Equatable, Sendable {
    case event(VoxBridgeEvent)
    case connection(VoxBridgeConnectionEvent)
}

public protocol VoxBridgeClientProtocol: Sendable {
    var isConnected: Bool { get async }
    func connect(
        to endpoint: VoxBridgeEndpoint,
        credentials: VoxBridgeAuthCredentials?
    ) async throws
    func start(
        direction: TranslationDirection,
        asrContextTerms: [String]
    ) async throws
    func sendAudioFrame(_ data: Data) async throws
    func setTranslationDirection(_ direction: TranslationDirection) async throws
    func finish() async throws
    func outputs() async -> AsyncStream<VoxBridgeClientOutput>
    func disconnect() async
}

public enum VoxBridgeClientError: LocalizedError, Equatable, Sendable {
    case notConnected
    case connectionFailed
    case sendFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "VoxBridge is not connected."
        case .connectionFailed:
            "VoxBridge connection failed."
        case .sendFailed:
            "VoxBridge send failed."
        }
    }
}
