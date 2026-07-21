import Foundation

public struct HTTPHeaders: Equatable, Sendable {
    private let storage: [String: String]

    public init(_ fields: [String: String]) {
        var normalized: [String: String] = [:]
        for key in fields.keys.sorted() {
            normalized[key.lowercased()] = fields[key]
        }
        storage = normalized
    }

    public subscript(name: String) -> String? {
        storage[name.lowercased()]
    }
}

public struct HTTPTransportResponse: @unchecked Sendable {
    public let statusCode: Int
    public let headers: HTTPHeaders
    public let body: Data
    public let cookies: [HTTPCookie]

    public init(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        cookies: [HTTPCookie] = []
    ) {
        self.statusCode = statusCode
        self.headers = HTTPHeaders(headers)
        self.body = body
        self.cookies = cookies
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse
}

public enum HTTPTransportError: LocalizedError, Equatable, Sendable {
    case invalidResponse

    public var errorDescription: String? {
        "VoxBridge authentication request returned an invalid response."
    }
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    public func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let url = response.url else {
            throw HTTPTransportError.invalidResponse
        }

        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            fields[String(describing: key)] = String(describing: value)
        }
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: fields,
            for: url
        )
        return HTTPTransportResponse(
            statusCode: response.statusCode,
            headers: fields,
            body: body,
            cookies: cookies
        )
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
