import CryptoKit
import Foundation
import Network

final class LocalVoxBridgeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "VoxHaloTests.LocalVoxBridgeServer")
    private let fragmentedText: String
    private let expectedCookie: String?
    private let startState = ListenerStartState()
    private let lock = NSLock()
    private var handlers: [LocalWebSocketConnection] = []

    init(fragmentedText: String, expectedCookie: String? = nil) throws {
        self.fragmentedText = fragmentedText
        self.expectedCookie = expectedCookie
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startState.install(continuation)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port,
                              let url = URL(string: "ws://127.0.0.1:\(port.rawValue)/ws") else {
                            startState.fail(LocalServerError.failedToBind)
                            return
                        }
                        startState.succeed(url)
                    case let .failed(error):
                        startState.fail(error)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
            startState.fail(CancellationError())
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let handlers = handlers
        self.handlers.removeAll()
        lock.unlock()
        for handler in handlers {
            handler.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        let handler = LocalWebSocketConnection(
            connection: connection,
            queue: queue,
            fragmentedText: fragmentedText,
            expectedCookie: expectedCookie
        )
        lock.lock()
        handlers.append(handler)
        lock.unlock()
        handler.start()
    }
}

private final class LocalWebSocketConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let fragmentedText: String
    private let expectedCookie: String?
    private var requestData = Data()

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        fragmentedText: String,
        expectedCookie: String?
    ) {
        self.connection = connection
        self.queue = queue
        self.fragmentedText = fragmentedText
        self.expectedCookie = expectedCookie
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveHandshake()
            case .failed, .cancelled:
                self?.connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveHandshake() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { requestData.append(data) }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            guard requestData.range(of: Data("\r\n\r\n".utf8)) != nil else {
                receiveHandshake()
                return
            }
            completeHandshake()
        }
    }

    private func completeHandshake() {
        guard let request = String(data: requestData, encoding: .utf8),
              let key = header("Sec-WebSocket-Key", in: request),
              expectedCookie.map({ expected in
                  header("Cookie", in: request)?.contains(expected) == true
              }) ?? true else {
            connection.cancel()
            return
        }

        let source = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let accept = Data(Insecure.SHA1.hash(data: source)).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n"
            + "\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed {
            [weak self] error in
            guard error == nil else {
                self?.connection.cancel()
                return
            }
            self?.sendFragmentedMessage()
        })
    }

    private func sendFragmentedMessage() {
        let payload = Data(fragmentedText.utf8)
        let split = max(1, payload.count / 2)
        let first = frame(
            payload: payload.prefix(split),
            isFinal: false,
            opcode: 0x1
        )
        let second = frame(
            payload: payload.suffix(from: split),
            isFinal: true,
            opcode: 0x0
        )
        connection.send(content: first, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                self?.connection.cancel()
                return
            }
            self?.connection.send(content: second, completion: .contentProcessed { _ in })
        })
    }

    private func header(_ name: String, in request: String) -> String? {
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            if key.caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: separator)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func frame(
        payload: some DataProtocol,
        isFinal: Bool,
        opcode: UInt8
    ) -> Data {
        let payload = Data(payload)
        var data = Data([isFinal ? 0x80 | opcode : opcode])
        if payload.count < 126 {
            data.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            data.append(126)
            data.append(UInt8((payload.count >> 8) & 0xFF))
            data.append(UInt8(payload.count & 0xFF))
        } else {
            data.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        data.append(payload)
        return data
    }
}

private final class ListenerStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    func install(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func succeed(_ url: URL) {
        complete(.success(url))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private enum LocalServerError: Error {
    case failedToBind
}
