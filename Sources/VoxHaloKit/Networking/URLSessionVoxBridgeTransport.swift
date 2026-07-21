import Foundation

public final class URLSessionVoxBridgeTransport: VoxBridgeTransport, @unchecked Sendable {
    private let request: URLRequest
    private let state = State()
    private lazy var delegate = WebSocketDelegate(owner: self)
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }()
    private lazy var task = session.webSocketTask(with: request)

    public init(url: URL, cookies: [HTTPCookie]) {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        self.request = request
    }

    public func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                switch state.installOpenContinuation(continuation) {
                case .start:
                    task.resume()
                case .resumeSuccess:
                    continuation.resume()
                case let .resumeFailure(error):
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            state.cancelOpen()
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    public func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func sendBinary(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func receive() async throws -> VoxBridgeTransportMessage {
        do {
            switch try await task.receive() {
            case let .string(text):
                return .text(text)
            case let .data(data):
                return .binary(data)
            @unknown default:
                return .closed
            }
        } catch {
            if state.isClosed || task.closeCode != .invalid {
                return .closed
            }
            throw error
        }
    }

    public func close() async throws {
        state.markClosed()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    fileprivate func didOpen() {
        state.completeOpen(.success(()))
    }

    fileprivate func didClose() {
        state.markClosed()
    }

    fileprivate func didComplete(error: Error?) {
        guard let error else { return }
        state.completeOpen(.failure(error))
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {
    private weak var owner: URLSessionVoxBridgeTransport?

    init(owner: URLSessionVoxBridgeTransport) {
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        owner?.didOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        owner?.didClose()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        owner?.didComplete(error: error)
    }
}

private final class State: @unchecked Sendable {
    enum InstallAction {
        case start
        case resumeSuccess
        case resumeFailure(Error)
    }

    private enum OpenState {
        case idle
        case waiting(CheckedContinuation<Void, Error>)
        case opened
        case failed(Error)
    }

    private let lock = NSLock()
    private var openState: OpenState = .idle
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func installOpenContinuation(
        _ continuation: CheckedContinuation<Void, Error>
    ) -> InstallAction {
        lock.lock()
        defer { lock.unlock() }
        switch openState {
        case .idle:
            openState = .waiting(continuation)
            return .start
        case .opened:
            return .resumeSuccess
        case let .failed(error):
            return .resumeFailure(error)
        case .waiting:
            return .resumeFailure(VoxBridgeTransportError.alreadyOpening)
        }
    }

    func completeOpen(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if case let .waiting(value) = openState {
            continuation = value
            openState = switch result {
            case .success: .opened
            case let .failure(error): .failed(error)
            }
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancelOpen() {
        completeOpen(.failure(CancellationError()))
    }

    func markClosed() {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        closed = true
        if case let .waiting(value) = openState {
            continuation = value
            openState = .failed(VoxBridgeTransportError.closedDuringOpening)
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: VoxBridgeTransportError.closedDuringOpening)
    }
}

private enum VoxBridgeTransportError: Error {
    case alreadyOpening
    case closedDuringOpening
}
