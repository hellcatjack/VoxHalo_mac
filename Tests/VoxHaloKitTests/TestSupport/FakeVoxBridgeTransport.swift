import Foundation
@testable import VoxHaloKit

enum FakeVoxBridgeError: LocalizedError, Sendable {
    case operation(String)

    var errorDescription: String? {
        switch self {
        case let .operation(secret): secret
        }
    }
}

actor FakeVoxBridgeTransport: VoxBridgeTransport {
    enum SentKind: Equatable, Sendable {
        case text
        case binary
    }

    private var queuedReceives: [Result<VoxBridgeTransportMessage, Error>] = []
    private var receiveWaiters: [
        CheckedContinuation<VoxBridgeTransportMessage, Error>
    ] = []
    private var activeSendCount = 0

    let rejectsOpen: Bool
    let rejectsClose: Bool
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var sentKinds: [SentKind] = []
    private(set) var sentTexts: [String] = []
    private(set) var sentBinary: [Data] = []
    private(set) var maximumConcurrentSendCount = 0

    init(rejectsOpen: Bool = false, rejectsClose: Bool = false) {
        self.rejectsOpen = rejectsOpen
        self.rejectsClose = rejectsClose
    }

    func open() async throws {
        openCount += 1
        if rejectsOpen {
            throw FakeVoxBridgeError.operation("open password-private")
        }
    }

    func sendText(_ text: String) async throws {
        try await beginSend()
        sentKinds.append(.text)
        sentTexts.append(text)
    }

    func sendBinary(_ data: Data) async throws {
        try await beginSend()
        sentKinds.append(.binary)
        sentBinary.append(data)
    }

    func receive() async throws -> VoxBridgeTransportMessage {
        if !queuedReceives.isEmpty {
            return try queuedReceives.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func close() async throws {
        closeCount += 1
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: .closed)
        }
        if rejectsClose {
            throw FakeVoxBridgeError.operation("close cookie-private")
        }
    }

    func yield(_ message: VoxBridgeTransportMessage) {
        if receiveWaiters.isEmpty {
            queuedReceives.append(.success(message))
        } else {
            receiveWaiters.removeFirst().resume(returning: message)
        }
    }

    func yieldError(_ secret: String) {
        let error = FakeVoxBridgeError.operation(secret)
        if receiveWaiters.isEmpty {
            queuedReceives.append(.failure(error))
        } else {
            receiveWaiters.removeFirst().resume(throwing: error)
        }
    }

    private func beginSend() async throws {
        activeSendCount += 1
        maximumConcurrentSendCount = max(maximumConcurrentSendCount, activeSendCount)
        defer { activeSendCount -= 1 }
        try await Task.sleep(for: .milliseconds(10))
    }
}

actor FakeVoxBridgeAuthenticator: VoxBridgeAuthenticating {
    private let result: Result<[HTTPCookie], Error>
    private(set) var callCount = 0

    init(cookies: [HTTPCookie] = []) {
        result = .success(cookies)
    }

    init(error: Error) {
        result = .failure(error)
    }

    func login(
        endpoint: VoxBridgeEndpoint,
        credentials: VoxBridgeAuthCredentials?
    ) async throws -> [HTTPCookie] {
        callCount += 1
        return try result.get()
    }
}

actor RecordingVoxBridgeTransportFactory {
    let transport: FakeVoxBridgeTransport
    private(set) var callCount = 0
    private(set) var receivedURL: URL?
    private(set) var receivedCookies: [HTTPCookie] = []

    init(transport: FakeVoxBridgeTransport) {
        self.transport = transport
    }

    func make(url: URL, cookies: [HTTPCookie]) -> any VoxBridgeTransport {
        callCount += 1
        receivedURL = url
        receivedCookies = cookies
        return transport
    }
}
