import Foundation
import XCTest
@testable import VoxHaloKit

final class VoxBridgeClientTests: XCTestCase {
    private let endpoint = try! VoxBridgeEndpoint(validating:
        URL(string: "ws://127.0.0.1:9000/ws")!)

    func testStartAudioDirectionAndFinishAreSerialized() async throws {
        let transport = FakeVoxBridgeTransport()
        let client = makeClient(transport: transport)
        try await client.connect(to: endpoint, credentials: nil)

        async let first: Void = client.start(direction: .chineseToEnglish)
        async let second: Void = client.sendAudioFrame(Data([1, 2, 3, 4]))
        _ = try await (first, second)
        try await client.setTranslationDirection(.englishToChinese)
        try await client.finish()

        let sentKinds = await transport.sentKinds
        let maximumConcurrentSendCount = await transport.maximumConcurrentSendCount
        let sentTexts = await transport.sentTexts
        let sentBinary = await transport.sentBinary
        XCTAssertEqual(sentKinds, [.text, .binary, .text, .text])
        XCTAssertEqual(maximumConcurrentSendCount, 1)
        XCTAssertEqual(sentTexts, [
            #"{"language":"Chinese","translation_direction":"zh2en","type":"start"}"#,
            #"{"translation_direction":"en2zh","type":"set_translation_direction"}"#,
            #"{"type":"finish"}"#
        ])
        XCTAssertEqual(sentBinary, [Data([1, 2, 3, 4])])
        await client.disconnect()
    }

    func testSendBeforeConnectFailsWithoutOpeningTransport() async throws {
        let transport = FakeVoxBridgeTransport()
        let client = makeClient(transport: transport)

        do {
            try await client.sendAudioFrame(Data([1]))
            XCTFail("Expected notConnected")
        } catch {
            XCTAssertEqual(error as? VoxBridgeClientError, .notConnected)
        }
        let openCount = await transport.openCount
        XCTAssertEqual(openCount, 0)
    }

    func testConnectionStateTracksOpenAndServerClose() async throws {
        let transport = FakeVoxBridgeTransport()
        let client = makeClient(transport: transport)
        let initiallyConnected = await client.isConnected

        try await client.connect(to: endpoint, credentials: nil)
        let connected = await client.isConnected
        await transport.yield(.closed)
        for _ in 0 ..< 100 where await client.isConnected {
            await Task.yield()
        }
        let connectedAfterClose = await client.isConnected

        XCTAssertFalse(initiallyConnected)
        XCTAssertTrue(connected)
        XCTAssertFalse(connectedAfterClose)
        await client.disconnect()
    }

    func testMalformedTextReportsParseErrorAndReceiveLoopContinues() async throws {
        let transport = FakeVoxBridgeTransport()
        let client = makeClient(transport: transport)
        try await client.connect(to: endpoint, credentials: nil)
        let outputs = await client.outputs()
        let collector = Task { await collectOutputs(2, from: outputs) }

        await transport.yield(.text("{"))
        await transport.yield(.text(#"{"type":"ready","sample_rate":16000}"#))
        let firstTwo = await collector.value

        XCTAssertEqual(firstTwo.map(\.summary), ["parseError", "event:ready"])
        await client.disconnect()
    }

    func testBinaryReceiveIsIgnoredAndUnknownTextEventIsDelivered() async throws {
        let transport = FakeVoxBridgeTransport()
        let client = makeClient(transport: transport)
        try await client.connect(to: endpoint, credentials: nil)
        let outputs = await client.outputs()
        let collector = Task { await collectOutputs(1, from: outputs) }

        await transport.yield(.binary(Data([9, 8, 7])))
        await transport.yield(.text(#"{"type":"future_event","text":"value"}"#))
        let values = await collector.value

        XCTAssertEqual(values.map(\.summary), ["event:unknown"])
        await client.disconnect()
    }

    func testCloseAndReceiveErrorProduceTypedRedactedOutputs() async throws {
        let closeTransport = FakeVoxBridgeTransport()
        let closeClient = makeClient(transport: closeTransport)
        try await closeClient.connect(to: endpoint, credentials: nil)
        let closeOutputs = await closeClient.outputs()
        let closeCollector = Task { await collectOutputs(1, from: closeOutputs) }
        await closeTransport.yield(.closed)
        let closed = await closeCollector.value
        XCTAssertEqual(closed.map(\.summary), ["disconnected"])
        await closeClient.disconnect()

        let errorTransport = FakeVoxBridgeTransport()
        let errorClient = makeClient(transport: errorTransport)
        try await errorClient.connect(to: endpoint, credentials: nil)
        let errorOutputs = await errorClient.outputs()
        let errorCollector = Task { await collectOutputs(1, from: errorOutputs) }
        await errorTransport.yieldError("password cookie authorization private")
        let received = await errorCollector.value

        XCTAssertEqual(received.map(\.summary), ["receiveError:network"])
        XCTAssertFalse(String(describing: received).contains("private"))
        await errorClient.disconnect()
    }

    func testReconnectClosesPreviousSocketWithoutFinishingSubscriptions() async throws {
        let transport = FakeVoxBridgeTransport()
        let client = makeClient(transport: transport)
        let outputs = await client.outputs()
        let collector = Task { await collectOutputs(2, from: outputs) }

        try await client.connect(to: endpoint, credentials: nil)
        try await client.connect(to: endpoint, credentials: nil)

        let openCount = await transport.openCount
        let closeCount = await transport.closeCount
        let connected = await collector.value
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(connected.map(\.summary), ["connected", "connected"])
        await client.disconnect()
    }

    func testLoginCookiesReachSocketFactoryAndRejectedLoginNeverBuildsSocket() async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1",
            .path: "/",
            .name: "voxbridge_session",
            .value: "session-123",
            .secure: "FALSE"
        ]))
        let transport = FakeVoxBridgeTransport()
        let factory = RecordingVoxBridgeTransportFactory(transport: transport)
        let authenticator = FakeVoxBridgeAuthenticator(cookies: [cookie])
        let client = VoxBridgeClient(
            transportFactory: { url, cookies in
                await factory.make(url: url, cookies: cookies)
            },
            authenticator: authenticator
        )

        try await client.connect(to: endpoint, credentials:
            VoxBridgeAuthCredentials(username: "admin", password: "p"))

        let receivedURL = await factory.receivedURL
        let receivedCookies = await factory.receivedCookies
        XCTAssertEqual(receivedURL, endpoint.webSocketURL)
        XCTAssertEqual(receivedCookies.first?.value, "session-123")
        await client.disconnect()

        let rejectedTransport = FakeVoxBridgeTransport()
        let rejectedFactory = RecordingVoxBridgeTransportFactory(
            transport: rejectedTransport
        )
        let rejectedClient = VoxBridgeClient(
            transportFactory: { url, cookies in
                await rejectedFactory.make(url: url, cookies: cookies)
            },
            authenticator: FakeVoxBridgeAuthenticator(
                error: VoxBridgeAuthenticationError.rejected
            )
        )
        do {
            try await rejectedClient.connect(to: endpoint, credentials:
                VoxBridgeAuthCredentials(username: "admin", password: "bad"))
            XCTFail("Expected rejected login")
        } catch {
            XCTAssertEqual(error as? VoxBridgeAuthenticationError, .rejected)
        }
        let factoryCallCount = await rejectedFactory.callCount
        let rejectedOpenCount = await rejectedTransport.openCount
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertEqual(rejectedOpenCount, 0)
    }

    func testDisconnectIsIdempotentFinishesStreamsAndIgnoresCloseFailure() async throws {
        let transport = FakeVoxBridgeTransport(rejectsClose: true)
        let client = makeClient(transport: transport)
        let outputs = await client.outputs()
        try await client.connect(to: endpoint, credentials: nil)

        await client.disconnect()
        await client.disconnect()
        let remaining = await collectAllOutputs(from: outputs)

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(remaining.map(\.summary), ["connected", "disconnected"])
    }

    private func makeClient(transport: FakeVoxBridgeTransport) -> VoxBridgeClient {
        VoxBridgeClient(
            transportFactory: { _, _ in transport },
            authenticator: FakeVoxBridgeAuthenticator()
        )
    }

}

private func collectOutputs(
    _ count: Int,
    from stream: AsyncStream<VoxBridgeClientOutput>
) async -> [VoxBridgeClientOutput] {
    var values: [VoxBridgeClientOutput] = []
    for await value in stream.prefix(count) {
        values.append(value)
    }
    return values
}

private func collectAllOutputs(
    from stream: AsyncStream<VoxBridgeClientOutput>
) async -> [VoxBridgeClientOutput] {
    var values: [VoxBridgeClientOutput] = []
    for await value in stream {
        values.append(value)
    }
    return values
}

private extension VoxBridgeClientOutput {
    var summary: String {
        switch self {
        case let .event(event):
            "event:\(event.type)"
        case let .connection(event):
            switch event {
            case .connected: "connected"
            case .disconnected: "disconnected"
            case .parseError: "parseError"
            case let .receiveError(category): "receiveError:\(category)"
            }
        }
    }
}
