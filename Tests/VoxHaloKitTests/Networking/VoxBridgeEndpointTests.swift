import Foundation
import XCTest
@testable import VoxHaloKit

final class VoxBridgeEndpointTests: XCTestCase {
    func testLoginURLUsesHTTPFamilySameAuthorityAndLoginPath() throws {
        let endpoint = try VoxBridgeEndpoint(validating:
            XCTUnwrap(URL(string: "wss://example.test:18024/ws?ignored=1#fragment")))

        XCTAssertEqual(endpoint.loginURL.absoluteString,
                       "https://example.test:18024/login")
        XCTAssertFalse(endpoint.isInsecure)
    }

    func testRuntimeEndpointRemovesUserInfoAndFragmentButKeepsSocketQuery() throws {
        let endpoint = try VoxBridgeEndpoint(validating: XCTUnwrap(URL(string:
            "ws://name:pass@example.test:9000/ws?room=7#token=private")))

        XCTAssertEqual(endpoint.webSocketURL.absoluteString,
                       "ws://example.test:9000/ws?room=7")
        XCTAssertEqual(endpoint.loginURL.absoluteString,
                       "http://example.test:9000/login")
        XCTAssertTrue(endpoint.isInsecure)
    }

    func testOnlyAbsoluteWebSocketURLsWithHostsValidate() throws {
        for text in ["ws://example.test/ws", "WSS://example.test/ws"] {
            XCTAssertNoThrow(try VoxBridgeEndpoint(validating: XCTUnwrap(URL(string: text))))
        }

        for text in [
            "https://example.test/ws",
            "ftp://example.test/ws",
            "ws:///missing-host",
            "/relative/ws"
        ] {
            XCTAssertThrowsError(
                try VoxBridgeEndpoint(validating: XCTUnwrap(URL(string: text))),
                text
            )
        }
    }

    func testValidationErrorNeverEchoesCredentialMaterial() throws {
        let text = "https://operator:password@example.test/ws?api_key=private#secret"

        XCTAssertThrowsError(
            try VoxBridgeEndpoint(validating: XCTUnwrap(URL(string: text)))
        ) { error in
            let description = String(describing: error)
            for secret in ["operator", "password", "private", "secret"] {
                XCTAssertFalse(description.contains(secret), secret)
            }
        }
    }
}
