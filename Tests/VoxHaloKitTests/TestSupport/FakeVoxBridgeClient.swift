import Foundation
@testable import VoxHaloKit

enum FakeSessionFailure: LocalizedError, Sendable {
    case operation(String)

    var errorDescription: String? {
        switch self {
        case let .operation(value): value
        }
    }
}

actor FakeVoxBridgeClient: VoxBridgeClientProtocol {
    private let calls: CallRecorder
    private let connectError: (any Error & Sendable)?
    private let startError: (any Error & Sendable)?
    private var continuation: AsyncStream<VoxBridgeClientOutput>.Continuation?
    private var startProbe: (@Sendable () async -> Void)?

    private(set) var connected = false
    private(set) var connectCount = 0
    private(set) var startCount = 0
    private(set) var disconnectCount = 0
    private(set) var audioFrames: [Data] = []
    private(set) var receivedEndpoint: VoxBridgeEndpoint?
    private(set) var receivedCredentials: VoxBridgeAuthCredentials?
    private(set) var receivedDirection: TranslationDirection?

    init(
        calls: CallRecorder,
        connectError: (any Error & Sendable)? = nil,
        startError: (any Error & Sendable)? = nil
    ) {
        self.calls = calls
        self.connectError = connectError
        self.startError = startError
    }

    var isConnected: Bool { connected }

    func outputs() -> AsyncStream<VoxBridgeClientOutput> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: VoxBridgeClientOutput.self
        )
        self.continuation = continuation
        return stream
    }

    func connect(
        to endpoint: VoxBridgeEndpoint,
        credentials: VoxBridgeAuthCredentials?
    ) async throws {
        calls.record("connect")
        connectCount += 1
        receivedEndpoint = endpoint
        receivedCredentials = credentials
        if let connectError { throw connectError }
        connected = true
        continuation?.yield(.connection(.connected))
    }

    func start(direction: TranslationDirection) async throws {
        calls.record("client.start:\(direction.backendDirection)")
        startCount += 1
        receivedDirection = direction
        if let startProbe { await startProbe() }
        if let startError { throw startError }
    }

    func sendAudioFrame(_ data: Data) async throws {
        calls.record("audio.send")
        audioFrames.append(data)
    }

    func setTranslationDirection(_ direction: TranslationDirection) async throws {
        calls.record("client.direction:\(direction.backendDirection)")
    }

    func finish() async throws {
        calls.record("finish")
    }

    func disconnect() async {
        calls.record("disconnect")
        disconnectCount += 1
        connected = false
    }

    func emit(_ output: VoxBridgeClientOutput) {
        continuation?.yield(output)
    }

    func setStartProbe(_ probe: @escaping @Sendable () async -> Void) {
        startProbe = probe
    }
}
