import Foundation
import XCTest
@testable import VoxHaloKit

final class VoxBridgeClientLoopbackTests: XCTestCase {
    func testFragmentedServerTextArrivesAsOneEventWithLoginCookieHandshake() async throws {
        let server = try LocalVoxBridgeServer(
            fragmentedText: #"{"type":"ready","sample_rate":16000}"#,
            expectedCookie: "voxbridge_session=session-123"
        )
        let url = try await server.start()
        defer { server.stop() }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1",
            .path: "/",
            .name: "voxbridge_session",
            .value: "session-123",
            .secure: "FALSE"
        ]))
        let client = VoxBridgeClient(
            authenticator: FakeVoxBridgeAuthenticator(cookies: [cookie])
        )
        let outputs = await client.outputs()
        let collector = Task { await collectLoopbackOutputs(2, from: outputs) }

        try await client.connect(
            to: VoxBridgeEndpoint(validating: url),
            credentials: VoxBridgeAuthCredentials(username: "admin", password: "p")
        )
        let received = await collector.value

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.first, .connection(.connected))
        guard case let .event(event) = received.last else {
            XCTFail("Expected one reassembled ready event")
            await client.disconnect()
            return
        }
        XCTAssertEqual(event.type, .ready)
        XCTAssertEqual(event.sampleRate, 16_000)
        await client.disconnect()
    }
}

private func collectLoopbackOutputs(
    _ count: Int,
    from stream: AsyncStream<VoxBridgeClientOutput>
) async -> [VoxBridgeClientOutput] {
    var values: [VoxBridgeClientOutput] = []
    for await value in stream.prefix(count) {
        values.append(value)
    }
    return values
}
