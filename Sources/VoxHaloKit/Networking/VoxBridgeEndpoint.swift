import Foundation

public struct VoxBridgeEndpoint: Equatable, Sendable {
    public let webSocketURL: URL

    public init(validating url: URL) throws {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        scheme == "ws" || scheme == "wss",
        let host = components.host,
        !host.isEmpty else {
            throw VoxBridgeEndpointError.invalid
        }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.fragment = nil
        guard let normalized = components.url else {
            throw VoxBridgeEndpointError.invalid
        }
        webSocketURL = normalized
    }

    public var loginURL: URL {
        var components = URLComponents(
            url: webSocketURL,
            resolvingAgainstBaseURL: false
        )!
        components.scheme = isInsecure ? "http" : "https"
        components.path = "/login"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url!
    }

    public var isInsecure: Bool {
        webSocketURL.scheme?.lowercased() == "ws"
    }
}

public enum VoxBridgeEndpointError: LocalizedError, Equatable, Sendable {
    case invalid

    public var errorDescription: String? {
        "VoxBridge endpoint must be an absolute ws:// or wss:// URL with a host."
    }
}
