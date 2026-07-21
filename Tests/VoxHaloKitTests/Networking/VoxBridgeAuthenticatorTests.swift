import Foundation
import XCTest
@testable import VoxHaloKit

final class VoxBridgeAuthenticatorTests: XCTestCase {
    func testAuthenticationPostsEscapedFormAndReturnsCookies() async throws {
        let transport = FakeHTTPTransport(response: HTTPTransportResponse(
            statusCode: 303,
            headers: ["Set-Cookie": "voxbridge_session=session-123; Path=/"],
            body: Data("must never appear in errors".utf8)
        ))
        let endpoint = try VoxBridgeEndpoint(validating:
            XCTUnwrap(URL(string: "ws://127.0.0.1:9000/ws?room=7")))
        let credentials = VoxBridgeAuthCredentials(
            username: "operator name",
            password: "p&ss=word"
        )

        let cookies = try await VoxBridgeAuthenticator(transport: transport).login(
            endpoint: endpoint,
            credentials: credentials
        )
        let recordedRequest = await transport.lastRequest
        let request = try XCTUnwrap(recordedRequest)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9000/login")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8),
                       "password=p%26ss%3Dword&username=operator%20name")
        XCTAssertEqual(cookies.first?.name, "voxbridge_session")
        XCTAssertEqual(cookies.first?.value, "session-123")
    }

    func testMissingCredentialsSkipHTTPCompletely() async throws {
        let transport = FakeHTTPTransport(response: HTTPTransportResponse(
            statusCode: 500,
            headers: [:],
            body: Data()
        ))
        let endpoint = try VoxBridgeEndpoint(validating:
            XCTUnwrap(URL(string: "wss://example.test/ws")))

        let cookies = try await VoxBridgeAuthenticator(transport: transport).login(
            endpoint: endpoint,
            credentials: nil
        )

        XCTAssertTrue(cookies.isEmpty)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testEveryStatusFrom200Through399IsAccepted() async throws {
        let endpoint = try VoxBridgeEndpoint(validating:
            XCTUnwrap(URL(string: "wss://example.test/ws")))
        let credentials = VoxBridgeAuthCredentials(username: "admin", password: "p")

        for status in [200, 204, 299, 300, 303, 399] {
            let transport = FakeHTTPTransport(response: HTTPTransportResponse(
                statusCode: status,
                headers: [:],
                body: Data()
            ))
            let cookies = try await VoxBridgeAuthenticator(transport: transport).login(
                endpoint: endpoint,
                credentials: credentials
            )
            XCTAssertTrue(cookies.isEmpty, "HTTP \(status)")
        }
    }

    func test401UsesExactSafeMessage() async throws {
        let error = await authenticationError(statusCode: 401)

        XCTAssertEqual(error?.localizedDescription,
                       "VoxBridge authentication failed.")
    }

    func testOtherFailuresContainOnlyStatusAndNeverResponseOrCredentialData() async throws {
        let bodySecret = "body-private"
        let cookieSecret = "cookie-private"
        let username = "operator-private"
        let password = "password-private"
        let transport = FakeHTTPTransport(response: HTTPTransportResponse(
            statusCode: 503,
            headers: ["Set-Cookie": "session=\(cookieSecret)"],
            body: Data(bodySecret.utf8)
        ))
        let endpoint = try VoxBridgeEndpoint(validating: XCTUnwrap(URL(string:
            "wss://url-user:url-password@example.test/ws?token=url-private")))

        do {
            _ = try await VoxBridgeAuthenticator(transport: transport).login(
                endpoint: endpoint,
                credentials: VoxBridgeAuthCredentials(username: username, password: password)
            )
            XCTFail("Expected authentication failure")
        } catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("HTTP 503"))
            for secret in [
                bodySecret, cookieSecret, username, password, "url-user", "url-password",
                "url-private"
            ] {
                XCTAssertFalse(description.contains(secret), secret)
            }
        }
    }

    func testTransportErrorsAreWrappedWithoutLeakingTheirDescription() async throws {
        struct LeakyError: LocalizedError {
            var errorDescription: String? {
                "operator password cookie authorization query-private"
            }
        }
        let transport = FakeHTTPTransport(error: LeakyError())
        let endpoint = try VoxBridgeEndpoint(validating:
            XCTUnwrap(URL(string: "wss://example.test/ws")))

        do {
            _ = try await VoxBridgeAuthenticator(transport: transport).login(
                endpoint: endpoint,
                credentials: VoxBridgeAuthCredentials(username: "operator", password: "password")
            )
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "VoxBridge authentication request failed.")
        }
    }

    func testHTTPHeadersLookupIsCaseInsensitive() {
        let response = HTTPTransportResponse(
            statusCode: 200,
            headers: ["sEt-CoOkIe": "session=value"],
            body: Data()
        )

        XCTAssertEqual(response.headers["SET-COOKIE"], "session=value")
        XCTAssertEqual(response.headers["set-cookie"], "session=value")
    }

    private func authenticationError(statusCode: Int) async -> Error? {
        do {
            let transport = FakeHTTPTransport(response: HTTPTransportResponse(
                statusCode: statusCode,
                headers: [:],
                body: Data("secret".utf8)
            ))
            let endpoint = try VoxBridgeEndpoint(validating:
                XCTUnwrap(URL(string: "wss://example.test/ws")))
            _ = try await VoxBridgeAuthenticator(transport: transport).login(
                endpoint: endpoint,
                credentials: VoxBridgeAuthCredentials(username: "admin", password: "secret")
            )
            return nil
        } catch {
            return error
        }
    }
}
