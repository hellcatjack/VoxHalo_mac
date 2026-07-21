import Foundation
@testable import VoxHaloKit

actor FakeHTTPTransport: HTTPTransport {
    private let result: Result<HTTPTransportResponse, Error>
    private(set) var requests: [URLRequest] = []

    init(response: HTTPTransportResponse) {
        result = .success(response)
    }

    init(error: Error) {
        result = .failure(error)
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        return try result.get()
    }

    var lastRequest: URLRequest? { requests.last }
}
