import Foundation

public typealias VoxBridgeTransportFactory = @Sendable (
    URL,
    [HTTPCookie]
) async throws -> any VoxBridgeTransport

public actor VoxBridgeClient: VoxBridgeClientProtocol {
    private let transportFactory: VoxBridgeTransportFactory
    private let authenticator: any VoxBridgeAuthenticating

    private var transport: (any VoxBridgeTransport)?
    private var receiveTask: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?
    private var sendTailID = 0
    private var connectionGeneration = 0
    private var subscribers: [
        UUID: AsyncStream<VoxBridgeClientOutput>.Continuation
    ] = [:]

    public init(
        transportFactory: @escaping VoxBridgeTransportFactory = { url, cookies in
            URLSessionVoxBridgeTransport(url: url, cookies: cookies)
        },
        authenticator: any VoxBridgeAuthenticating = VoxBridgeAuthenticator()
    ) {
        self.transportFactory = transportFactory
        self.authenticator = authenticator
    }

    public var isConnected: Bool { transport != nil }

    public func connect(
        to endpoint: VoxBridgeEndpoint,
        credentials: VoxBridgeAuthCredentials?
    ) async throws {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        _ = await cleanupCurrentTransport()

        let cookies = try await authenticator.login(
            endpoint: endpoint,
            credentials: credentials
        )
        try ensureCurrent(generation)

        let candidate: any VoxBridgeTransport
        do {
            candidate = try await transportFactory(endpoint.webSocketURL, cookies)
            try await candidate.open()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VoxBridgeClientError.connectionFailed
        }

        guard generation == connectionGeneration else {
            try? await candidate.close()
            throw CancellationError()
        }

        transport = candidate
        broadcast(.connection(.connected))
        receiveTask = Task { [weak self, candidate] in
            await self?.receiveLoop(using: candidate, generation: generation)
        }
    }

    public func start(direction: TranslationDirection) async throws {
        try await sendText(VoxBridgeMessageEncoder.start(direction))
    }

    public func sendAudioFrame(_ data: Data) async throws {
        try await enqueue(.binary(data))
    }

    public func setTranslationDirection(
        _ direction: TranslationDirection
    ) async throws {
        try await sendText(VoxBridgeMessageEncoder.setTranslationDirection(direction))
    }

    public func finish() async throws {
        try await sendText(VoxBridgeMessageEncoder.finish())
    }

    public func outputs() async -> AsyncStream<VoxBridgeClientOutput> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: VoxBridgeClientOutput.self
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        subscribers[id] = continuation
        return stream
    }

    public func disconnect() async {
        connectionGeneration &+= 1
        let hadConnection = await cleanupCurrentTransport()
        if hadConnection {
            broadcast(.connection(.disconnected))
        }
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    private func sendText(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoxBridgeClientError.sendFailed
        }
        try await enqueue(.text(text))
    }

    private func enqueue(_ message: OutgoingMessage) async throws {
        guard let transport else {
            throw VoxBridgeClientError.notConnected
        }

        sendTailID &+= 1
        let id = sendTailID
        let previous = sendTail
        let task = Task {
            if let previous {
                try await previous.value
            }
            try Task.checkCancellation()
            switch message {
            case let .text(text):
                try await transport.sendText(text)
            case let .binary(data):
                try await transport.sendBinary(data)
            }
        }
        sendTail = task

        do {
            try await task.value
            if sendTailID == id { sendTail = nil }
        } catch {
            if sendTailID == id { sendTail = nil }
            throw VoxBridgeClientError.sendFailed
        }
    }

    private func receiveLoop(
        using source: any VoxBridgeTransport,
        generation: Int
    ) async {
        while !Task.isCancelled {
            let message: VoxBridgeTransportMessage
            do {
                message = try await source.receive()
            } catch {
                guard !Task.isCancelled,
                      isCurrent(source, generation: generation) else {
                    return
                }
                broadcast(.connection(.receiveError("network")))
                await release(source, generation: generation)
                return
            }

            guard !Task.isCancelled,
                  isCurrent(source, generation: generation) else {
                return
            }
            switch message {
            case let .text(text):
                do {
                    broadcast(.event(try VoxBridgeEventParser.parse(text)))
                } catch {
                    broadcast(.connection(.parseError))
                }
            case .binary:
                continue
            case .closed:
                broadcast(.connection(.disconnected))
                await release(source, generation: generation)
                return
            }
        }
    }

    private func release(
        _ source: any VoxBridgeTransport,
        generation: Int
    ) async {
        guard isCurrent(source, generation: generation) else { return }
        transport = nil
        receiveTask = nil
        sendTail?.cancel()
        sendTail = nil
        try? await source.close()
    }

    @discardableResult
    private func cleanupCurrentTransport() async -> Bool {
        let source = transport
        let receiving = receiveTask
        let sending = sendTail
        transport = nil
        receiveTask = nil
        sendTail = nil
        receiving?.cancel()
        sending?.cancel()
        if let source {
            try? await source.close()
        }
        if let sending {
            _ = try? await sending.value
        }
        if let receiving {
            await receiving.value
        }
        return source != nil
    }

    private func ensureCurrent(_ generation: Int) throws {
        guard generation == connectionGeneration else {
            throw CancellationError()
        }
    }

    private func isCurrent(
        _ source: any VoxBridgeTransport,
        generation: Int
    ) -> Bool {
        generation == connectionGeneration && transport === source
    }

    private func broadcast(_ output: VoxBridgeClientOutput) {
        for continuation in subscribers.values {
            continuation.yield(output)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private enum OutgoingMessage: Sendable {
        case text(String)
        case binary(Data)
    }
}
