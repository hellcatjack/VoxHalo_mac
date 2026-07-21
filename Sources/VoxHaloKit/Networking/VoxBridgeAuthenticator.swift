import Foundation

public struct VoxBridgeAuthenticator: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    public func login(
        endpoint: VoxBridgeEndpoint,
        credentials: VoxBridgeAuthCredentials?
    ) async throws -> [HTTPCookie] {
        guard let credentials else { return [] }

        var request = URLRequest(url: endpoint.loginURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        let fields = [
            ("password", credentials.password),
            ("username", credentials.username)
        ]
        request.httpBody = Data(fields.map { key, value in
            "\(Self.percentEncode(key))=\(Self.percentEncode(value))"
        }.joined(separator: "&").utf8)

        let response: HTTPTransportResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw VoxBridgeAuthenticationError.requestFailed
        }

        guard (200 ... 399).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw VoxBridgeAuthenticationError.rejected
            }
            throw VoxBridgeAuthenticationError.httpStatus(response.statusCode)
        }

        if !response.cookies.isEmpty {
            return response.cookies
        }
        guard let cookieHeader = response.headers["set-cookie"] else {
            return []
        }
        return HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": cookieHeader],
            for: endpoint.loginURL
        )
    }

    private static func percentEncode(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39,
                 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}

public enum VoxBridgeAuthenticationError: LocalizedError, Equatable, Sendable {
    case rejected
    case httpStatus(Int)
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .rejected:
            "VoxBridge authentication failed."
        case let .httpStatus(statusCode):
            "VoxBridge authentication failed (HTTP \(statusCode))."
        case .requestFailed:
            "VoxBridge authentication request failed."
        }
    }
}
