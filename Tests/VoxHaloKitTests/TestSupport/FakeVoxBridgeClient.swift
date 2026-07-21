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
    private let finishError: (any Error & Sendable)?
    private let finishOutput: VoxBridgeClientOutput?
    private var continuation: AsyncStream<VoxBridgeClientOutput>.Continuation?
    private var startProbe: (@Sendable () async -> Void)?
    private var remainingSendFailures: Int
    private var sendsAreSuspended: Bool
    private var connectIsSuspended: Bool
    private var sendWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var connectWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private(set) var connected = false
    private(set) var connectCount = 0
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var disconnectCount = 0
    private(set) var audioFrames: [Data] = []
    private(set) var sendAttempts: [Data] = []
    private(set) var receivedEndpoint: VoxBridgeEndpoint?
    private(set) var receivedCredentials: VoxBridgeAuthCredentials?
    private(set) var receivedDirection: TranslationDirection?
    private(set) var connectionRequests: [
        (VoxBridgeEndpoint, VoxBridgeAuthCredentials?)
    ] = []
    private(set) var startDirections: [TranslationDirection] = []
    private(set) var operations: [String] = []

    init(
        calls: CallRecorder,
        connectError: (any Error & Sendable)? = nil,
        startError: (any Error & Sendable)? = nil,
        finishError: (any Error & Sendable)? = nil,
        finishOutput: VoxBridgeClientOutput? = nil,
        sendFailureCount: Int = 0,
        sendsSuspended: Bool = false,
        connectSuspended: Bool = false
    ) {
        self.calls = calls
        self.connectError = connectError
        self.startError = startError
        self.finishError = finishError
        self.finishOutput = finishOutput
        self.remainingSendFailures = sendFailureCount
        self.sendsAreSuspended = sendsSuspended
        self.connectIsSuspended = connectSuspended
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
        operations.append("connect")
        connectCount += 1
        receivedEndpoint = endpoint
        receivedCredentials = credentials
        connectionRequests.append((endpoint, credentials))
        if connectIsSuspended {
            try await waitForConnectResume()
        }
        if let connectError { throw connectError }
        connected = true
        continuation?.yield(.connection(.connected))
    }

    func start(direction: TranslationDirection) async throws {
        calls.record("client.start:\(direction.backendDirection)")
        operations.append("start:\(direction.backendDirection)")
        startCount += 1
        receivedDirection = direction
        startDirections.append(direction)
        if let startProbe { await startProbe() }
        if let startError { throw startError }
    }

    func sendAudioFrame(_ data: Data) async throws {
        sendAttempts.append(data)
        guard connected else { throw VoxBridgeClientError.notConnected }
        if sendsAreSuspended {
            try await waitForSendResume()
        }
        if remainingSendFailures > 0 {
            remainingSendFailures -= 1
            throw VoxBridgeClientError.sendFailed
        }
        audioFrames.append(data)
        let byte = data.first.map(String.init) ?? "empty"
        calls.record("audio.send")
        operations.append("audio:\(byte)")
    }

    func setTranslationDirection(_ direction: TranslationDirection) async throws {
        calls.record("client.direction:\(direction.backendDirection)")
        operations.append("direction:\(direction.backendDirection)")
    }

    func finish() async throws {
        calls.record("finish")
        operations.append("finish")
        finishCount += 1
        if let finishOutput {
            recordOutputOperation(finishOutput)
            continuation?.yield(finishOutput)
        }
        if let finishError { throw finishError }
    }

    func disconnect() async {
        calls.record("disconnect")
        operations.append("disconnect")
        disconnectCount += 1
        connected = false
    }

    func emit(_ output: VoxBridgeClientOutput) {
        switch output {
        case .connection(.connected): connected = true
        case .connection(.disconnected): connected = false
        default: break
        }
        recordOutputOperation(output)
        continuation?.yield(output)
    }

    func setStartProbe(_ probe: @escaping @Sendable () async -> Void) {
        startProbe = probe
    }

    func setSendsSuspended(_ suspended: Bool) {
        sendsAreSuspended = suspended
        if !suspended {
            let waiters = sendWaiters.values
            sendWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func resumeSends() {
        setSendsSuspended(false)
    }

    func resumeConnects() {
        connectIsSuspended = false
        let waiters = connectWaiters.values
        connectWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func suspendConnects() {
        connectIsSuspended = true
    }

    func setConnected(_ connected: Bool) {
        self.connected = connected
    }

    func failNextSends(_ count: Int) {
        remainingSendFailures += max(0, count)
    }

    private func waitForSendResume() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sendWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelSendWaiter(id) }
        }
        try Task.checkCancellation()
    }

    private func waitForConnectResume() async throws {
        await withCheckedContinuation { continuation in
            connectWaiters[UUID()] = continuation
        }
        try Task.checkCancellation()
    }

    private func cancelSendWaiter(_ id: UUID) {
        sendWaiters.removeValue(forKey: id)?.resume()
    }

    private func recordOutputOperation(_ output: VoxBridgeClientOutput) {
        guard case let .event(event) = output else { return }
        switch event.type {
        case .final: calls.record("final")
        case .error: calls.record("error")
        default: break
        }
    }
}
